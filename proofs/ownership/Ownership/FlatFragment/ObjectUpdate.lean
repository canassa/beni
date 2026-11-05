import Ownership.FlatFragment.Objects

/-! The first flat fragment: the update of a record object, written in place
(#316, slice 2).

An update writes the object's one slot in place, once, after every new value.
Its Dead test reads the continuation per field (`recordLiveCells`): a live use
through the written object into a field the update keeps is no use of it, so
its route is the written array, and the frame shows that the value at a kept
field is the same before and after the write. The result's certificate comes
from the old object's certificate over its live fields (`objectsCertified`)
for the kept fields and from the checker's store tests for the new values. -/

/-! ### The update: the Dead test and the runtime -/

namespace Ownership.FlatFragment.Objects

open Soundness InPlaceSemantics HeapProof Ownership.FlatFragment.State Ownership.FlatFragment.Fields
open Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.LiveCells

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- The keep test of `recordLiveCells`: a rest of a use path that goes into a
field the update keeps. -/
def keepsField (written : List Nat) (rest : Path) : Bool :=
  match rest with
  | .element :: .field g :: _ => !written.contains g
  | _ => false

/-- The inner fold of `recordLiveCells` over the paths of one abstract value. -/
def recordPathStep (written : List Nat) (cs : List Origin) (p : Path) (acc : List Origin)
    (entry : Path × List Origin) : List Origin :=
  if isPrefix entry.1 p && cellOverlap entry.2 cs && keepsField written (p.drop entry.1.length) then acc
  else if isPrefix p entry.1 || isPrefix entry.1 p then union acc entry.2 else acc

theorem recordPathStep_mono (written : List Nat) (cs : List Origin) (p : Path) :
    ∀ acc entry, ∀ o ∈ acc, o ∈ recordPathStep written cs p acc entry := by
  intro acc entry o member
  unfold recordPathStep
  split
  · exact member
  · split
    · exact Ownership.FlatFragment.Description.mem_union acc entry.2 o (Or.inl member)
    · exact member

def recordUseStep (written : List Nat) (cs : List Origin) (env : Env Abstract) (acc : List Origin)
    (use : Var × Path) : List Origin :=
  match env.lookup use.1 with
  | none => union acc [.unknown]
  | some a => a.paths.foldl (recordPathStep written cs use.2) acc

theorem recordUseStep_mono (written : List Nat) (cs : List Origin) (env : Env Abstract) :
    ∀ acc use, ∀ o ∈ acc, o ∈ recordUseStep written cs env acc use := by
  intro acc use o member
  unfold recordUseStep
  split
  · exact Ownership.FlatFragment.Description.mem_union acc [.unknown] o (Or.inl member)
  · exact foldl_mono _ (recordPathStep_mono written cs use.2) _ acc o member

theorem recordLiveCells_eq_fold (written : List Nat) (cs : List Origin) (env : Env Abstract) (l : Live) :
    recordLiveCells written cs env l = l.foldl (recordUseStep written cs env) [] := by
  unfold recordLiveCells recordUseStep recordPathStep keepsField
  rfl

/-- A cell list of a live use's abstract that the update's Dead test does not
skip is in its live cells. -/
theorem cells_in_recordLiveCells (written : List Nat) (cs : List Origin) (env : Env Abstract) (l : Live)
    (x : Var) (p q : Path) (a : Abstract) (ds : List Origin) (use : (x, p) ∈ l) (found : env.lookup x = some a)
    (path : (q, ds) ∈ a.paths) (related : (isPrefix p q || isPrefix q p) = true)
    (notSkipped : (isPrefix q p && cellOverlap ds cs && keepsField written (p.drop q.length)) = false) :
    ∀ o ∈ ds, o ∈ recordLiveCells written cs env l := by
  intro o member
  rw [recordLiveCells_eq_fold]
  apply foldl_member (recordUseStep written cs env) (recordUseStep_mono written cs env) l [] (x, p) use o
  intro acc
  unfold recordUseStep
  simp only [found]
  apply foldl_member (recordPathStep written cs p) (recordPathStep_mono written cs p) a.paths acc (q, ds) path o
  intro acc'
  unfold recordPathStep
  simp only [notSkipped, Bool.false_eq_true, if_false, related, if_true]
  exact Ownership.FlatFragment.Description.mem_union acc' ds o (Or.inr member)

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects
open Ownership.FlatFragment.Runtime Ownership.FlatFragment.Observe Ownership.FlatFragment.CheckerExtraction
open Ownership.FlatFragment.StateFrame

theorem value_assign_success {depth : Nat} {declarations : List Decl} {width : Nat} {fields : List Nat}
    {base : Atom} {values : List Atom} (state : ValueSemantics.State) (runtimeEnv : Env Observation)
    {xs vos : List Observation}
    (baseRun : ValueSemantics.atom runtimeEnv base = .ok (.list [.record xs]))
    (valuesRun : values.mapM (m := Except String) (ValueSemantics.atom runtimeEnv) = .ok vos) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.assign width fields base values)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (_, post) ← ValueSemantics.observeKept.run (valueTicked state)
        pure (.list [.record (assignFields xs fields vos)], post)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [ValueSemantics.eval, ValueSemantics.tick, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set,
        liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [ValueSemantics.eval, ValueSemantics.tick, baseRun, valuesRun,
        valueTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
        MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-- The in-place state after an update's write of its object's slot. -/
def writesAfter (s : InPlaceSemantics.State) (previous stored : List InPlaceSemantics.Value) : Nat :=
  if previous == stored then s.writes else s.writes + 1

def heapAssigned (s : InPlaceSemantics.State) (c : Nat) (previous stored : List InPlaceSemantics.Value) : InPlaceSemantics.State :=
  { s with fuel := s.fuel - 1, writes := writesAfter s previous stored, heap := Array.set! s.heap c stored }

theorem heap_assign_success {depth : Nat} {declarations : List Decl} {width : Nat} {fields : List Nat}
    {base : Atom} {values : List Atom} (state : InPlaceSemantics.State) (runtimeEnv : Env InPlaceSemantics.Value)
    {c : Nat} {ws vws : List InPlaceSemantics.Value}
    (baseRun : InPlaceSemantics.atom runtimeEnv base = .ok (.ref c))
    (valuesRun : values.mapM (m := Except String) (InPlaceSemantics.atom runtimeEnv) = .ok vws)
    (slot : state.heap[c]? = some [.record ws])
    (unlinked : ∀ v src f, (v, src, f) ∈ state.links → v ≠ c ∧ src ≠ c) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.assign width fields base values)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (_, post) ← InPlaceSemantics.observeKept.run
          (heapAssigned state c [.record ws] [.record (assignFields ws fields vws)])
        pure (.ref c, post)) := by
  have written := Ownership.LinkedWriteRun.writeCounted_unlinked_run { state with fuel := state.fuel - 1 }
    (stored := [.record (assignFields ws fields vws)]) (previous := [.record ws]) slot unlinked
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set,
        liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp only [StateT.run] at written
      simp [InPlaceSemantics.eval, InPlaceSemantics.tick, baseRun, valuesRun, InPlaceSemantics.array, slot,
        heapTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
        MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw,
        Option.toExcept, written, heapAssigned, writesAfter]

end Ownership.FlatFragment.Objects


open Ownership Ownership.FlatFragment.State Ownership.FlatFragment.Fields Soundness InPlaceSemantics HeapProof
open Ownership.FlatFragment.HeapPreservation

namespace Ownership.FlatFragment.Objects

/-- A typed value has a value at each typed field path. -/
theorem kinded_fields_exists {kinds : Nat → Option Ty} {heap : Heap} :
    ∀ {p : Path} {ty u : Ty} {w : Value}, Kinded kinds ty w → fieldTyAt ty p = some u →
      ∃ w', projectHeap heap w p = some w' ∧ Kinded kinds u w' := by
  intro p
  induction p with
  | nil =>
    intro ty u w typed at_p
    simp [fieldTyAt] at at_p
    subst at_p
    exact ⟨w, rfl, typed⟩
  | cons step rest ih =>
    intro ty u w typed at_p
    cases step <;> cases ty <;> simp [fieldTyAt] at at_p
    rename_i i ts
    cases h : ts[i]? with
    | none => simp [h] at at_p
    | some t =>
      simp only [h] at at_p
      obtain ⟨ws, rfl, lenW, fields⟩ := kinded_record_inv typed
      obtain ⟨x, ws_i⟩ := index_of_same_length lenW.symm h
      obtain ⟨w', projected, typed'⟩ := ih (fields i t x h ws_i) at_p
      exact ⟨w', by simp [projectHeap, ws_i, projected], typed'⟩

/-- A path of a flat abstract at a field path is a root path of the abstract
there. -/
theorem paths_atPath_root {ds : List Origin} :
    ∀ {q : Path} {ty u : Ty} {a : Abstract}, FlatAbstract ty a → fieldTyAt ty q = some u →
      (q, ds) ∈ a.paths → ([], ds) ∈ (a.atPath q).paths := by
  intro q
  induction q with
  | nil => intro ty u a _ _ member; simpa [Abstract.atPath] using member
  | cons step rest ih =>
    intro ty u a shape at_q member
    cases step <;> cases ty <;> simp [fieldTyAt] at at_q
    rename_i i ts
    cases h : ts[i]? with
    | none => simp [h] at at_q
    | some t =>
      simp only [h] at at_q
      rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
      · simp [Abstract.paths] at member
      · obtain ⟨j, y, r', at_j, same, path⟩ := mem_record_paths member
        simp only [List.cons.injEq, Step.field.injEq] at same
        obtain ⟨rfl, rfl⟩ := same
        obtain ⟨a', as_i, shape'⟩ := flatAbstract_record_field len fields h
        rw [as_i] at at_j
        cases at_j
        simp only [Abstract.atPath, as_i, Option.getD_some]
        exact ih shape' at_q path

/-- The cells a flat abstract records at a field path to a list are that
list's roots. -/
theorem cellsAt_atPath_list {ty u : Ty} {a : Abstract} {q : Path} {cs : List Origin} {e : Abstract}
    {ex : Certificate} {o : Origin}
    (shape : FlatAbstract ty a) (at_q : fieldTyAt ty q = some u) (at_a : a.atPath q = .list cs e ex)
    (member : o ∈ a.cellsAt q) : o ∈ cs := by
  obtain ⟨ds, path, inDs⟩ := mem_cellsAt a q o member
  have root := paths_atPath_root shape at_q path
  rw [at_a] at root
  simp only [Abstract.paths, List.mem_cons, List.mem_map, Prod.mk.injEq] at root
  rcases root with ⟨_, rfl⟩ | ⟨⟨r, ds'⟩, _, bad, _⟩
  · exact inDs
  · cases bad

/-- A field path is an immutable path. -/
theorem immutablePath_of_fields {q : Path} (fields : ∀ s ∈ q, ∃ i, s = Step.field i) :
    immutablePath q = true := by
  unfold immutablePath
  apply List.all_eq_true.mpr
  intro s member
  obtain ⟨i, rfl⟩ := fields s member
  rfl

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects

open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Description

local instance assignStepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance assignStepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance assignOriginReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance assignOriginLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- A path longer than another is no prefix of it. -/
theorem isPrefix_longer (p r : Path) (s : Step) : isPrefix (p ++ s :: r) p = false := by
  unfold isPrefix
  cases h : (p ++ s :: r == List.take (p ++ s :: r).length p) with
  | false => rfl
  | true =>
    have eq := beq_iff_eq.mp h
    have lenEq := congrArg List.length eq
    simp only [List.length_append, List.length_cons, List.length_take] at lenEq
    omega

theorem keepsField_nil (written : List Nat) : keepsField written [] = false := rfl

/-- The update's Dead test keeps every array of a live projected value apart
from the written object: the cells at and below a live path are its live
cells (#316). -/
theorem assign_live_apart {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {cs : List Origin} {root : Nat} {pinned : List Origin} {written : List Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (scope : liveScope aenv after = .ok ())
    (afterSub : ∀ use ∈ after, use ∈ live)
    (receiverNamed : named gamma cs root)
    (separate : ∀ r, named gamma cs r → ¬ named gamma (union (recordLiveCells written cs aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o w w', env.lookup x = some (o, w) → projectHeap hs.heap w p = some w' →
      ∀ q c, ArrayAt hs.heap w' q c → c ≠ root := by
  intro x p use o w w' binding projected q c located same
  subst same
  obtain ⟨a, abstractBinding⟩ := liveScope_lookup_exists scope use
  obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
  obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (afterSub _ use) declared
  have shape0 := inv.abstractShapes x ty a declared abstractBinding
  have described := inv.described x p (afterSub _ use) o w a ty t w' binding abstractBinding declared at_p
    projected
  obtain ⟨origin, member, address⟩ := described.1.1 q c located
  obtain ⟨q0, ds, typedPath, inDs⟩ := mem_paths_of_mem_cells
    (namesAt_subset_cells (flatAbstract_entry (ds := declarations) (flatAbstract_atPath shape0 at_p)) q origin member)
  obtain ⟨q', path⟩ := mem_paths_entryAbstract declarations t (a.atPath p) q0 ds typedPath
  have below := atPath_paths_prefix shape0 at_p path
  have inLive := cells_in_recordLiveCells written cs aenv after x p (p ++ q') a ds use abstractBinding below
    (by simp [isPrefix_append])
    (by
      cases q' with
      | nil => simp [keepsField_nil]
      | cons s r => simp [isPrefix_longer])
    origin inDs
  exact separate c receiverNamed ⟨origin, mem_union _ _ origin (Or.inl inLive), address⟩

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects

open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Description

local instance assignStepReflBEq' : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance assignStepLawfulBEq' : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance assignOriginReflBEq' : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance assignOriginLawfulBEq' : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- A live use whose route goes through the written object goes into a field
the update keeps: otherwise the Dead test reads the object's cells there as
live (#316). -/
theorem assign_route {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {cs : List Origin} {root : Nat} {pinned : List Origin} {written : List Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (scope : liveScope aenv after = .ok ())
    (afterSub : ∀ use ∈ after, use ∈ live)
    (receiverNamed : named gamma cs root)
    (separate : ∀ r, named gamma cs r → ¬ named gamma (union (recordLiveCells written cs aenv after) pinned) r) :
    ∀ x p, (x, p) ∈ after → ∀ o w q rest, env.lookup x = some (o, w) → p = q ++ .element :: rest →
      ArrayAt hs.heap w q root → keepsField written (.element :: rest) = true := by
  intro x p use o w q rest binding route located
  cases kept : keepsField written (.element :: rest) with
  | true => rfl
  | false =>
    exfalso
    obtain ⟨a, abstractBinding⟩ := liveScope_lookup_exists scope use
    obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
    obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (afterSub _ use) declared
    rw [route] at at_p
    obtain ⟨origin, member, address⟩ :=
      inv.named x o w a binding abstractBinding q root (tyAt_route_immutable at_p) located
    obtain ⟨ds, path, inDs⟩ := mem_cellsAt a q origin member
    have dropped : p.drop q.length = .element :: rest := by rw [route]; simp
    have inLive := cells_in_recordLiveCells written cs aenv after x p q a ds use abstractBinding path
      (by rw [route]; simp [isPrefix_append]) (by rw [dropped, kept]; simp) origin inDs
    exact separate root receiverNamed ⟨origin, mem_union _ _ origin (Or.inl inLive), address⟩

/-- After the update's write, every live projection reads the same value: a
route through another array finds it unchanged, and a route through the
written object reads a field the update keeps (#316). -/
theorem assign_projected {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {after : Live} {escapes : List Origin} {written : List Nat} {c : Nat} {ws ws' : List Value} {next : Heap}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (heapEq : next = hs.heap.set! c [.record ws'])
    (slot : hs.heap[c]? = some [.record ws])
    (keptSame : ∀ g, g ∉ written → ws'[g]? = ws[g]?)
    (route : ∀ x p, (x, p) ∈ after → ∀ o w q rest, env.lookup x = some (o, w) → p = q ++ .element :: rest →
      ArrayAt hs.heap w q c → keepsField written (.element :: rest) = true) :
    ∀ x p, (x, p) ∈ after → ∀ o w, env.lookup x = some (o, w) →
      projectHeap next w p = projectHeap hs.heap w p := by
  intro x p use o w binding
  obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
  obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (afterSub _ use) declared
  have lt : c < hs.heap.size := (Array.getElem?_eq_some_iff.mp slot).1
  rcases tyAt_cases at_p with fields | ⟨q, rest, ts', rfl, at_q, at_rest⟩
  · exact projectHeap_fields (fieldTyAt_fields fields)
  · rw [projectHeap_append, projectHeap_append, projectHeap_fields (heap' := hs.heap) (fieldTyAt_fields at_q)]
    cases hq : projectHeap hs.heap w q with
    | none => rfl
    | some u =>
      simp only [Option.bind_some]
      cases u with
      | ref d =>
        have located : ArrayAt hs.heap w q d := by
          simpa using arrayAt_of_project hq (AtPath.here (.ref d))
        by_cases same : d = c
        · subst same
          have keep := route x _ use o w q rest binding rfl located
          match rest, keep, at_rest with
          | .field g :: rest', keep, at_rest =>
            have notWritten : g ∉ written := by
              simp [keepsField] at keep
              exact keep
            have restFields : ∀ s ∈ rest', ∃ i, s = Step.field i :=
              fun s m => fieldTyAt_fields at_rest s (List.mem_cons_of_mem _ m)
            have newSlot : next[d]? = some [.record ws'] := by rw [heapEq]; simp [lt]
            simp only [projectHeap, newSlot, slot]
            rw [keptSame g notWritten]
            cases ws[g]? with
            | none => rfl
            | some v => exact projectHeap_fields restFields
          | [], keep, _ => simp [keepsField] at keep
          | .element :: _, keep, _ => simp [keepsField] at keep
          | .capture _ :: _, keep, _ => simp [keepsField] at keep
          | .env :: _, keep, _ => simp [keepsField] at keep
        · have other : next[d]? = hs.heap[d]? := by rw [heapEq]; exact lookup_set_other hs.heap c _ same
          simp only [projectHeap, other]
          cases hs.heap[d]? with
          | none => rfl
          | some xs =>
            match xs with
            | [.record ys] => exact projectHeap_fields (fieldTyAt_fields at_rest)
            | [] => rfl
            | [.int _] => rfl
            | [.ref _] => rfl
            | [.closure _ _] => rfl
            | a :: _ :: _ => cases a <;> rfl
      | int _ => simp [projectHeap]
      | record _ => simp [projectHeap]
      | closure _ _ => simp [projectHeap]

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects

open Ownership.FlatFragment.Observe Ownership.FlatFragment.RepresentsDepth Ownership.FlatFragment.FiniteReach

/-- The certificate of a record object over its live fields, as the flat
relation's `objectsCertified` states it for one object. -/
def ObjectCert (heap : Heap) (c : Nat) (ws : List Value) (ex : Certificate) (L : Nat → Prop) : Prop :=
  ∀ keep : List Bool, (∀ g, keep[g]? = some true → L g) →
    ∀ n os fps, RepresentsMany heap n (selectFields keep ws) os fps →
      (ex.deep = true → (c :: fps).Nodup) ∧
      (ex.spine = true → ∀ v ∈ selectFields keep ws, ∀ p d, containerPath p = true →
        ArrayAt heap v p d → (c :: fps).count d = 1)

theorem objectCert_single {heap : Heap} {c : Nat} {ws : List Value} {ex : Certificate} {L : Nat → Prop}
    (cert : ObjectCert heap c ws ex L) {i : Nat} {w : Value} (live : L i) (at_i : ws[i]? = some w)
    {n : Nat} {o : Observation} {fp : List Nat} (rep : Represents heap n w o fp) :
    (ex.deep = true → (c :: fp).Nodup) ∧
    (ex.spine = true → ∀ p d, containerPath p = true → ArrayAt heap w p d → (c :: fp).count d = 1) := by
  have selected := selectFields_single i ws w at_i
  have many : RepresentsMany heap n (selectFields (List.replicate i false ++ [true]) ws) [o] (fp ++ []) := by
    rw [selected]; exact .cons rep .nil
  obtain ⟨deep, spine⟩ := cert _ (fun g kept => by rw [selectFields_single_mem kept]; exact live) n [o] _ many
  simp only [List.append_nil] at deep spine
  exact ⟨deep, fun s p d container located => spine s w (by rw [selected]; simp) p d container located⟩

/-- Two live fields of a certified object reach no common array. -/
theorem objectCert_pair {heap : Heap} {c : Nat} {ws : List Value} {ex : Certificate} {L : Nat → Prop}
    (cert : ObjectCert heap c ws ex L) {i j : Nat} {wi wj : Value} (ne : i ≠ j) (liveI : L i) (liveJ : L j)
    (at_i : ws[i]? = some wi) (at_j : ws[j]? = some wj)
    (repI : ∃ n o fp, Represents heap n wi o fp) (repJ : ∃ n o fp, Represents heap n wj o fp) :
    (ex.deep = true → ∀ d, Reaches heap wi (.ref d) → ¬ Reaches heap wj (.ref d)) ∧
    (ex.spine = true → ∀ p d, containerPath p = true → ArrayAt heap wi p d → ¬ Reaches heap wj (.ref d)) := by
  obtain ⟨n1, o1, fp1, rep1⟩ := repI
  obtain ⟨n2, o2, fp2, rep2⟩ := repJ
  have rep1' := represents_of_depth rep1 (Nat.le_trans (represents_depth_bound rep1) (Nat.le_max_left n1 n2))
  have rep2' := represents_of_depth rep2 (Nat.le_trans (represents_depth_bound rep2) (Nat.le_max_right n1 n2))
  -- the pair in index order
  have both : ∀ {a b : Nat} {wa wb : Value} {oa ob : Observation} {fa fb : List Nat}, a < b → L a → L b →
      ws[a]? = some wa → ws[b]? = some wb →
      Represents heap (max n1 n2) wa oa fa → Represents heap (max n1 n2) wb ob fb →
      (ex.deep = true → (c :: (fa ++ fb)).Nodup) ∧
      (ex.spine = true → ∀ v ∈ [wa, wb], ∀ p d, containerPath p = true → ArrayAt heap v p d →
        (c :: (fa ++ fb)).count d = 1) := by
    intro a b wa wb oa ob fa fb lt liveA liveB at_a at_b repA repB
    have at_b' : ws[a + 1 + (b - a - 1)]? = some wb := by
      have : a + 1 + (b - a - 1) = b := by omega
      rw [this]; exact at_b
    have selected := selectFields_pair a (b - a - 1) ws wa wb at_a at_b'
    have many : RepresentsMany heap (max n1 n2)
        (selectFields (List.replicate a false ++ [true] ++ List.replicate (b - a - 1) false ++ [true]) ws)
        [oa, ob] (fa ++ (fb ++ [])) := by
      rw [selected]; exact .cons repA (.cons repB .nil)
    obtain ⟨deep, spine⟩ := cert _ (fun g kept => by
      rcases selectFields_pair_mem kept with rfl | rfl
      · exact liveA
      · have : a + 1 + (b - a - 1) = b := by omega
        rw [this]; exact liveB) _ _ _ many
    simp only [List.append_nil] at deep spine
    exact ⟨deep, fun s v member p d container located =>
      spine s v (by rw [selected]; exact member) p d container located⟩
  have ordered : ∀ {d : Nat}, (∀ (fa fb : List Nat), (c :: (fa ++ fb)).Nodup → d ∈ fa → d ∈ fb → False) := by
    intro d fa fb nodup inA inB
    have := (List.nodup_cons.mp nodup).2
    exact (List.nodup_append.mp this).2.2 d inA d inB rfl
  refine ⟨fun deep d reachI reachJ => ?_, fun spine p d container located reachJ => ?_⟩
  · have inI := represents_reach_member rep1' reachI
    have inJ := represents_reach_member rep2' reachJ
    rcases Nat.lt_or_gt_of_ne ne with lt | gt
    · exact ordered fp1 fp2 ((both lt liveI liveJ at_i at_j rep1' rep2').1 deep) inI inJ
    · exact ordered fp2 fp1 ((both gt liveJ liveI at_j at_i rep2' rep1').1 deep) inJ inI
  · have inI := represents_reach_member rep1' (reaches_of_atPath located)
    have inJ := represents_reach_member rep2' reachJ
    have countTwo : ∀ (fa fb : List Nat), d ∈ fa → d ∈ fb → 2 ≤ (c :: (fa ++ fb)).count d := by
      intro fa fb inA inB
      have ha := List.count_pos_iff.mpr inA
      have hb := List.count_pos_iff.mpr inB
      rw [List.count_cons, List.count_append]
      omega
    rcases Nat.lt_or_gt_of_ne ne with lt | gt
    · have once := (both lt liveI liveJ at_i at_j rep1' rep2').2 spine wi (by simp) p d container located
      have := countTwo fp1 fp2 inI inJ
      omega
    · have once := (both gt liveJ liveI at_j at_i rep2' rep1').2 spine wi (by simp) p d container located
      have := countTwo fp2 fp1 inJ inI
      omega

/-- A one-slot object whose record's fields repeat no array, reach no common
array and do not reach the object repeats no array. -/
theorem slot_footprint_nodup {heap : Heap} {c : Nat} {ws : List Value}
    (slot : heap[c]? = some [.record ws])
    (cApart : ∀ w ∈ ws, ¬ Reaches heap w (.ref c))
    (each : ∀ (i : Nat) w, ws[i]? = some w → ∀ n o fp, Represents heap n w o fp → fp.Nodup)
    (apart : ∀ (i j : Nat), i ≠ j → ∀ wi wj, ws[i]? = some wi → ws[j]? = some wj →
      ∀ d, Reaches heap wi (.ref d) → ¬ Reaches heap wj (.ref d)) :
    ∀ n o fp, Represents heap n (.ref c) o fp → fp.Nodup := by
  refine fresh_footprint_nodup slot ?_ ?_ ?_
  · intro z member reach
    simp only [List.mem_singleton] at member
    subst member
    cases reach with
    | field fieldMember inner => exact cApart _ fieldMember inner
  · intro i w at_i n o fp rep
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at at_i
      subst at_i
      cases rep with
      | record children =>
        exact representsMany_nodup_of_apart children (fun i w o' c' at_i _ rep' => each i w at_i _ o' c' rep') apart
    | succ i => simp at at_i
  · intro i j ne wi wj at_i at_j
    cases i with
    | zero =>
      cases j with
      | zero => exact absurd rfl ne
      | succ j => simp at at_j
    | succ i => simp at at_i

/-- A one-slot object holds each container array of its record's fields once. -/
theorem slot_footprint_once {heap : Heap} {c : Nat} {ws : List Value}
    (slot : heap[c]? = some [.record ws])
    (cApart : ∀ w ∈ ws, ¬ Reaches heap w (.ref c))
    (eachOnce : ∀ (i : Nat) w, ws[i]? = some w → ∀ n o fp, Represents heap n w o fp →
      ∀ p d, containerPath p = true → ArrayAt heap w p d → fp.count d = 1)
    (apart : ∀ (i j : Nat), i ≠ j → ∀ wi wj, ws[i]? = some wi → ws[j]? = some wj →
      ∀ p d, containerPath p = true → ArrayAt heap wi p d → ¬ Reaches heap wj (.ref d)) :
    ∀ n o fp, Represents heap n (.ref c) o fp →
      ∀ p d, containerPath p = true → ArrayAt heap (.ref c) (.element :: p) d → fp.count d = 1 := by
  refine fresh_footprint_once slot ?_ ?_ ?_
  · intro z member reach
    simp only [List.mem_singleton] at member
    subst member
    cases reach with
    | field fieldMember inner => exact cApart _ fieldMember inner
  · intro i w at_i n o fp rep p d container located
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at at_i
      subst at_i
      cases rep with
      | record children =>
        cases located with
        | @field _ k x q _ ws_k inner =>
          have containerQ : containerPath q = true := by simpa [containerPath] using container
          exact countMany_eq_of_holder children k x ws_k
            (fun j y at_j ne reach => apart k j (Ne.symm ne) x y ws_k at_j q d containerQ inner reach)
            (fun o' fp' rep' => eachOnce k x ws_k _ o' fp' rep' q d containerQ inner)
    | succ i => simp at at_i
  · intro i j ne wi wj at_i at_j
    cases i with
    | zero =>
      cases j with
      | zero => exact absurd rfl ne
      | succ j => simp at at_j
    | succ i => simp at at_i

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects

open Ownership.FlatFragment.StateFrame Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame
open Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime Ownership.FlatFragment.Naming
open Ownership.FlatFragment.Support Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal
open Ownership.FlatFragment.Push Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope
open Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.Static Ownership.FlatFragment.Let
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.Env Ownership.FlatFragment.InferAssign
open Ownership.FlatFragment.Length Ownership.FlatFragment.Description

local instance assignStepReflBEq'' : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance assignStepLawfulBEq'' : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance assignOriginReflBEq'' : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance assignOriginLawfulBEq'' : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

theorem mem_cellsOf {xs : List Abstract} {a : Abstract} {o : Origin} (member : a ∈ xs) (inA : o ∈ a.cells) :
    o ∈ cellsOf xs := by
  unfold cellsOf
  have general : ∀ (ys : List Abstract) (acc : List Origin), (o ∈ acc ∨ ∃ b ∈ ys, o ∈ b.cells) →
      o ∈ ys.foldl (fun xs a => union xs a.cells) acc := by
    intro ys
    induction ys with
    | nil => intro acc h; rcases h with h | ⟨b, hb, _⟩; exact h; simp at hb
    | cons y ys ih =>
      intro acc h
      simp only [List.foldl_cons]
      apply ih
      rcases h with h | ⟨b, hb, inB⟩
      · exact Or.inl (mem_union _ _ _ (Or.inl h))
      · rcases List.mem_cons.mp hb with rfl | later
        · exact Or.inl (mem_union _ _ _ (Or.inr inB))
        · exact Or.inr ⟨b, later, inB⟩
  exact general xs [] (Or.inr ⟨a, member, inA⟩)

theorem mem_assignKept {written : List Nat} {fs : List Abstract} {g : Nat} {a : Abstract}
    (at_g : fs[g]? = some a) (kept : g ∉ written) : a ∈ assignKept written fs := by
  unfold assignKept
  apply List.mem_map.mpr
  refine ⟨(a, g), List.mem_filter.mpr ⟨List.mem_zipIdx_iff_getElem?.mpr at_g, ?_⟩, rfl⟩
  simp [kept]

end Ownership.FlatFragment.Objects

namespace Ownership.FlatFragment.Objects

open Ownership.FlatFragment.StateFrame Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame
open Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime Ownership.FlatFragment.Naming
open Ownership.FlatFragment.Support Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal
open Ownership.FlatFragment.Push Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope
open Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.Static Ownership.FlatFragment.Let
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.Env Ownership.FlatFragment.InferAssign
open Ownership.FlatFragment.Length Ownership.FlatFragment.Description

local instance assignStepReflBEq3 : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance assignStepLawfulBEq3 : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance assignOriginReflBEq3 : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance assignOriginLawfulBEq3 : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- The exclusivity test of several stored values passes for each one alone. -/
theorem storeExclusive_single {ctx : Context} {xs : List Abstract} {later other : List Origin} {a : Abstract}
    (h : storeExclusive ctx xs later other = true) (member : a ∈ xs) :
    storeExclusive ctx [a] later other = true := by
  obtain ⟨deepAll, sepVals, _⟩ := storeExclusive_facts_many h
  obtain ⟨eachSep, _⟩ := separatedValues_sound sepVals
  unfold storeExclusive at h ⊢
  rw [Bool.and_eq_true] at h
  have owned := List.all_eq_true.mp h.2 a member
  simp only [List.all_cons, List.all_nil, Bool.and_true, deepAll a member, Bool.true_or, Bool.true_and,
    separatedValues, List.zipIdx_cons, List.zipIdx_nil, List.drop_succ_cons, List.drop_zero, eachSep a member]
  simpa using owned

/-- The spine test of several stored values passes for each one alone. -/
theorem storeSpines_single {ctx : Context} {xs : List Abstract} {later other : List Origin} {a : Abstract}
    (h : storeSpines ctx xs later other = true) (member : a ∈ xs) :
    storeSpines ctx [a] later other = true := by
  unfold storeSpines at h ⊢
  rw [Bool.and_eq_true] at h ⊢
  refine ⟨separatedPaths_sublist (by simpa using sublist_flatMap_of_mem (f := containers) member) h.1, ?_⟩
  rw [List.all_eq_true] at h ⊢
  intro e eMember
  have eMember' : e ∈ xs.flatMap containers := by
    simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil] at eMember
    exact List.mem_flatMap.mpr ⟨a, member, eMember⟩
  have this := h.2 e eMember'
  obtain ⟨p, cs⟩ := e
  simp only [Bool.and_eq_true] at this ⊢
  refine ⟨this.1, ?_⟩
  simp only [List.all_cons, List.all_nil, Bool.and_true]
  exact List.all_eq_true.mp this.2 a member

/-- The cell list of a container of a flat value's representation is the cell
list of a container of the value's abstract. -/
theorem containers_entry_mem {ds : List Decl} {t : Ty} {a : Abstract} (shape : FlatAbstract t a)
    {p : Path} {cs : List Origin} (member : (p, cs) ∈ containers (entryAbstract ds t a)) :
    ∃ p', (p', cs) ∈ containers a := by
  have inSnd : cs ∈ (containers (entryAbstract ds t a)).map Prod.snd := List.mem_map.mpr ⟨(p, cs), member, rfl⟩
  rw [containers_snd_eq, pathKinds_entryAbstract shape, ← containers_snd_eq] at inSnd
  obtain ⟨⟨p', cs'⟩, member', same⟩ := List.mem_map.mp inSnd
  cases same
  exact ⟨p', member'⟩

/-- A path of a flat value's representation has a path of the value's abstract
with the same cell list and the same container kind. -/
theorem paths_entry_mem {ds : List Decl} {t : Ty} {a : Abstract} (shape : FlatAbstract t a)
    {q : Path} {cs : List Origin} (member : (q, cs) ∈ (entryAbstract ds t a).paths) :
    ∃ q', (q', cs) ∈ a.paths ∧ containerPath q' = containerPath q := by
  have inKinds : (containerPath q, cs) ∈ pathKinds (entryAbstract ds t a) :=
    List.mem_map.mpr ⟨(q, cs), member, rfl⟩
  rw [pathKinds_entryAbstract shape] at inKinds
  obtain ⟨⟨q', cs'⟩, member', same⟩ := List.mem_map.mp inKinds
  simp only [Prod.mk.injEq] at same
  obtain ⟨kind, rfl⟩ := same
  exact ⟨q', member', kind⟩

theorem cellOverlap_false_of_subset {as bs bs' : List Origin} (h : cellOverlap as bs = false)
    (sub : ∀ o ∈ bs', o ∈ bs) : cellOverlap as bs' = false := by
  have each := cellOverlap_false as bs h
  unfold cellOverlap
  rw [List.any_eq_false]
  intro x hx
  rw [Bool.not_eq_true, List.any_eq_false]
  intro y hy
  rw [each x hx y (sub y hy)]
  simp

theorem named_of_subset {gamma : Naming} {xs ys : List Origin} {d : Nat} (h : named gamma xs d)
    (sub : ∀ o ∈ xs, o ∈ ys) : named gamma ys d := by
  obtain ⟨o, member, address⟩ := h
  exact ⟨o, sub o member, address⟩

theorem mem_union_right_of {xs ys : List Origin} {o : Origin} (h : o ∈ ys) : o ∈ union xs ys :=
  mem_union _ _ _ (Or.inr h)

/-- An update written in place (#316). -/
theorem assign_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {width : Nat} {written : List Nat} {base : Atom} {values : List Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.assign width written base values) = .ok type)
    (usesLive : ∀ use ∈ uses (.assign width written base values), use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.assign width written base values) after site).run before =
      .ok (result, next)) :
    Preserved declarations depth env vs hs (.assign width written base values) after aenv tenv
      next.facts.escapes result type := by
  obtain ⟨ts, baseTyped, rfl, widthEq, lengths, valuesTyped⟩ := exprType_assign_success typed
  have flatObject : FlatType (.object ts) := flat_atom_type inv baseTyped
  have flatFields : ∀ t ∈ ts, FlatType t := by
    cases flatObject with
    | object _ fs => exact fs
  cases root : atomRoot base with
  | none =>
    obtain ⟨n, rfl, bad⟩ := atom_int_of_root_none baseTyped root
    cases bad
  | some kp =>
  rcases kp with ⟨k, p0⟩
  obtain ⟨tk, declared, at_p0⟩ := atom_fieldType_of_root baseTyped root
  have p0Fields := fieldTyAt_fields at_p0
  obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env tenv inv.typeKeys declared
  rcases pair with ⟨o0, w0⟩
  obtain ⟨a0, abstractBinding⟩ := lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
  have shape0 := inv.abstractShapes k tk a0 declared abstractBinding
  have tags0 := inv.tags k tk a0 o0 w0 declared abstractBinding binding
  -- the base's observation is a record object, by its type
  obtain ⟨ob, obsQ, obTyped⟩ :=
    projectObs_of_tyAt (inv.observationsTyped k tk o0 w0 declared binding) (tyAt_of_fieldTyAt at_p0)
  obtain ⟨oslot, rfl, slotTyped⟩ := obsTyped_object_slot obTyped
  cases oslot with
  | int _ => simp [obsTyped] at slotTyped
  | list _ => simp [obsTyped] at slotTyped
  | closure _ _ => simp [obsTyped] at slotTyped
  | record xs =>
  obtain ⟨lenX, xsTyped⟩ := obsTyped_record_fields slotTyped
  -- the base's value is a record object, by the heap typing
  obtain ⟨kinds, state⟩ := inv.heapKinds
  obtain ⟨wb, projQ, kindedB⟩ :=
    kinded_fields_exists (heap := hs.heap) (state.env k tk o0 w0 declared binding) at_p0
  obtain ⟨c, rfl, kindC⟩ := kinded_object_inv kindedB
  obtain ⟨slotValue, slot, kindedSlot⟩ := state.object_slot kindC
  obtain ⟨ws, rfl, lenW, kindedFields⟩ := kinded_record_inv kindedSlot
  have unlinked := state.object_unlinked kindC
  have valueBase := value_atom_of_root root (valueEnv_lookup binding) obsQ
  have heapBase := heap_atom_of_root root (heapEnv_lookup binding) projQ
  have abstractBase := abstractAtom_of_root root abstractBinding shape0 tags0 projQ at_p0
  -- the checker
  obtain ⟨childFuel, b, vabs, _, scope, baseRun, valuesRun, step⟩ :=
    infer_assign_success defaultConfig accepted
  rw [abstractBase] at baseRun
  cases baseRun
  have tagsQ := resultTags_project tags0 (flatAbstract_entry shape0) (fieldTyAt_entryType at_p0) projQ
  rw [entryAbstract_atPath shape0 (tyAt_of_fieldTyAt at_p0)] at tagsQ
  rcases assignStep_success step with ⟨bottom, _, _⟩ | ⟨cs, fs, ex, atQ, demanded, resultEq⟩
  · rw [bottom, entryAbstract_bottom] at tagsQ
    cases tagsQ
  have shapeQ := flatAbstract_atPath shape0 (tyAt_of_fieldTyAt at_p0)
  rw [atQ] at shapeQ
  obtain ⟨noUnk, lenF, fieldsF⟩ : Origin.unknown ∉ cs ∧ ts.length = fs.length ∧
      ∀ (i : Nat) (t : Ty) (a : Abstract), ts[i]? = some t → fs[i]? = some a → FlatAbstract t a := by
    cases shapeQ with
    | object _ _ _ _ noUnk elementShape =>
      cases elementShape with
      | record _ _ len fields => exact ⟨noUnk, len, fields⟩
  have cNamed : named gamma cs c := by
    obtain ⟨origin, member, address⟩ := inv.named k o0 w0 a0 binding abstractBinding p0 c
      (immutablePath_of_fields p0Fields) (by simpa using arrayAt_of_project projQ (AtPath.here (.ref c)))
    exact ⟨origin, cellsAt_atPath_list shape0 at_p0 atQ member, address⟩
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig] at demanded
  have nextEscapes : next.facts.escapes = before.facts.escapes := demand_success_escapes demanded
  -- the values, typed as the fields they write
  have valueField : ∀ (j : Nat) (v : Atom), values[j]? = some v → ∃ f, written[j]? = some f ∧
      ∃ t, ts[f]? = some t ∧ atomType tenv v = .ok t := by
    intro j v at_j
    obtain ⟨f, at_f⟩ := index_of_same_length lengths.symm at_j
    have pair : (f, v) ∈ written.zip values := by
      apply List.mem_of_getElem? (i := j)
      rw [List.getElem?_zip_eq_some]
      exact ⟨at_f, at_j⟩
    obtain ⟨t, u, ts_f, atomTyped, equal⟩ := valuesTyped f v pair
    have same := ty_equal_flat_right (flatFields t (List.mem_of_getElem? ts_f)) equal
    subst same
    exact ⟨f, at_f, u, ts_f, atomTyped⟩
  have valuesTypedList : values.mapM (atomType tenv) = .ok (written.map fun f => ts[f]?.getD .int) := by
    refine mapM_ok_of_fields (by simp [lengths]) ?_
    intro j v u at_v at_u
    obtain ⟨f, at_f, t, ts_f, atomTyped⟩ := valueField j v at_v
    rw [List.getElem?_map, at_f] at at_u
    simp only [ts_f, Option.getD_some, Option.map_some, Option.some.injEq] at at_u
    subst at_u
    exact atomTyped
  have covValues : ∀ atom ∈ values, ∀ use ∈ atomUses atom, use ∈ live := by
    intro atom member use useMember
    apply usesLive
    change use ∈ union (fieldUses base ((List.range width).filter (!written.contains ·))) (atomsUses values)
    exact mem_union _ _ _ (Or.inr (List.mem_flatMap.mpr ⟨atom, member, useMember⟩))
  obtain ⟨vos, vws, vabs', valueVals, heapVals, absVals, lenVO, lenVW, lenVA, valFacts⟩ :=
    flat_atoms_values inv valuesTypedList covValues
  rw [absVals] at valuesRun
  cases valuesRun
  have newType : ∀ (j f : Nat), written[j]? = some f → ∃ t, ts[f]? = some t ∧
      (written.map fun f => ts[f]?.getD .int)[j]? = some t := by
    intro j f at_f
    obtain ⟨v, at_v⟩ := index_of_same_length lengths at_f
    obtain ⟨f', at_f', t, ts_f, _⟩ := valueField j v at_v
    rw [at_f] at at_f'
    cases at_f'
    exact ⟨t, ts_f, by simp [List.getElem?_map, at_f, ts_f]⟩
  -- the kept fields: live uses through the base's slot
  have keptLive : ∀ g, g < width → g ∉ written → (k, p0 ++ [.element, .field g]) ∈ live := by
    intro g lt notIn
    apply usesLive
    change _ ∈ union (fieldUses base ((List.range width).filter (!written.contains ·))) (atomsUses values)
    refine mem_union _ _ _ (Or.inl ?_)
    unfold fieldUses
    rw [atomUses_of_root root]
    simp [lt, notIn]
  have keptFacts : ∀ g, g ∉ written → ∀ w a o t, ws[g]? = some w → fs[g]? = some a → xs[g]? = some o →
      ts[g]? = some t →
      Corresponds hs.heap o w ∧ Describes gamma hs.heap (entryAbstract declarations t a) w ∧
      obsTyped declarations o t = true ∧ AllocatedFlatValue hs.heap w (entryType t) ∧
      ResultTags (entryType t) (entryAbstract declarations t a) w ∧
      ChainTags (entryType t) (entryAbstract declarations t a) o ∧
      TagsDeep hs.heap (entryType t) (entryAbstract declarations t a) w ∧ FlatAbstract t a ∧
      (k, p0 ++ [.element, .field g]) ∈ live := by
    intro g notIn w a o t ws_g fs_g xs_g ts_g
    have lt : g < width := by rw [← widthEq]; exact (List.getElem?_eq_some_iff.mp ts_g).1
    have use := keptLive g lt notIn
    have at_p : tyAt tk (p0 ++ [.element, .field g]) = some t := tyAt_object_field at_p0 ts_g
    have obsPath : projectObs o0 (p0 ++ [.element, .field g]) = some o := by
      rw [projectObs_append, obsQ]; simp [projectObs, xs_g]
    have valuePath : projectHeap hs.heap w0 (p0 ++ [.element, .field g]) = some w := by
      rw [projectHeap_append, projQ]; simp [projectHeap, slot, ws_g]
    have atField : a0.atPath (p0 ++ [.element, .field g]) = a := by
      rw [atPath_append_fields p0Fields, atQ]; simp [Abstract.atPath, fs_g]
    obtain ⟨o', w', obsPath', valuePath', paired⟩ := inv.bindings k _ use o0 w0 binding
    rw [obsPath] at obsPath'
    cases obsPath'
    rw [valuePath] at valuePath'
    cases valuePath'
    have described := inv.described k _ use o0 w0 a0 tk t w binding abstractBinding declared at_p valuePath
    rw [atField] at described
    obtain ⟨t', o'', w'', at_p', obsPath'', valuePath'', observed, allocated⟩ :=
      inv.bindingsTyped k _ use o0 w0 tk binding declared
    rw [at_p] at at_p'
    cases at_p'
    rw [obsPath] at obsPath''
    cases obsPath''
    rw [valuePath] at valuePath''
    cases valuePath''
    have deep := inv.deepTags k _ use o0 w0 tk a0 t w binding declared abstractBinding at_p valuePath
    rw [atField] at deep
    obtain ⟨tagsF, chainsF⟩ :=
      inv.liveTags k _ use o0 w0 tk a0 t o w binding declared abstractBinding at_p obsPath valuePath
    rw [atField] at tagsF chainsF
    exact ⟨paired, described, observed, allocated, tagsF, chainsF, deep, fieldsF g t a ts_g fs_g, use⟩
  -- the demand: Dead per field, Disjoint, Unescaped
  have deadSep := demand_success_live_separate inv.separating demanded
  have disjoint := demand_success_disjoint inv.separating demanded
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : c ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded cNamed represented
  have keptApart : ∀ g, g ∉ written → ∀ w, ws[g]? = some w → ¬ Reaches hs.heap w (.ref c) := by
    intro g notIn w ws_g
    have ts_g : ts[g]? = some (ts[g]'(by rw [← lenW]; exact (List.getElem?_eq_some_iff.mp ws_g).1)) :=
      List.getElem?_eq_getElem _
    obtain ⟨a, fs_g⟩ := index_of_same_length lenF ts_g
    obtain ⟨o, xs_g⟩ := index_of_same_length (lenW.trans lenX.symm) ws_g
    obtain ⟨_, described, _, _, _, _, _, shapeA, _⟩ := keptFacts g notIn w a o _ ws_g fs_g xs_g ts_g
    exact value_apart_root (flatAbstract_entry shapeA) described.1.1 cNamed disjoint (fun o' member => by
      rw [cells_entryAbstract shapeA] at member
      exact mem_union _ _ _ (Or.inl (mem_cellsOf (mem_assignKept fs_g notIn) member)))
  have newApart : ∀ (j : Nat) w, vws[j]? = some w → ¬ Reaches hs.heap w (.ref c) := by
    intro j w vws_j
    obtain ⟨f, at_f⟩ := index_of_same_length (lenVW.trans (List.length_map _)) vws_j
    obtain ⟨t, ts_f, us_j⟩ := newType j f at_f
    obtain ⟨o, vos_j⟩ := index_of_same_length (lenVW.trans lenVO.symm) vws_j
    obtain ⟨a, vabs_j⟩ := index_of_same_length (lenVW.trans lenVA.symm) vws_j
    obtain ⟨_, described, _, _, _, shapeA, _⟩ := valFacts j o w a t vos_j vws_j vabs_j us_j
    exact value_apart_root (flatAbstract_entry shapeA) described.1.1 cNamed disjoint (fun o' member => by
      rw [cells_entryAbstract shapeA] at member
      exact mem_union _ _ _ (Or.inr (mem_cellsOf (List.mem_of_getElem? vabs_j) member)))
  -- the new record, field by field
  have lenVabs : vabs.length = written.length := by rw [lenVA, List.length_map]
  have lenVws : vws.length = written.length := by rw [lenVW, List.length_map]
  have lenVos : vos.length = written.length := by rw [lenVO, List.length_map]
  obtain ⟨ws', ws'Def⟩ : ∃ ws', ws' = assignFields ws written vws := ⟨_, rfl⟩
  obtain ⟨xs', xs'Def⟩ : ∃ xs', xs' = assignFields xs written vos := ⟨_, rfl⟩
  obtain ⟨fs', fs'Def⟩ : ∃ fs', fs' = assignFields fs written vabs := ⟨_, rfl⟩
  have lenW' : ws'.length = ts.length := by rw [ws'Def, assignFields_length]; exact lenW
  have lenX' : xs'.length = ts.length := by rw [xs'Def, assignFields_length]; exact lenX
  have lenF' : fs'.length = ts.length := by rw [fs'Def, assignFields_length]; exact lenF.symm
  have keptSame : ∀ g, g ∉ written → ws'[g]? = ws[g]? := fun g notIn => by
    rw [ws'Def]; exact assignFields_kept notIn
  have fieldFacts : ∀ (i : Nat) w a o t, ws'[i]? = some w → fs'[i]? = some a → xs'[i]? = some o →
      ts[i]? = some t →
      Corresponds hs.heap o w ∧ Describes gamma hs.heap (entryAbstract declarations t a) w ∧
      obsTyped declarations o t = true ∧ AllocatedFlatValue hs.heap w (entryType t) ∧
      ResultTags (entryType t) (entryAbstract declarations t a) w ∧
      ChainTags (entryType t) (entryAbstract declarations t a) o ∧
      TagsDeep hs.heap (entryType t) (entryAbstract declarations t a) w ∧ FlatAbstract t a ∧
      Kinded kinds t w ∧ ¬ Reaches hs.heap w (.ref c) := by
    intro i w a o t ws_i fs_i xs_i ts_i
    rw [ws'Def] at ws_i
    rw [fs'Def] at fs_i
    rw [xs'Def] at xs_i
    rcases assignFields_source lenVws i w ws_i with ⟨notIn, oldW⟩ | ⟨j, at_j, vws_j, last⟩
    · rcases assignFields_source lenVabs i a fs_i with ⟨_, oldA⟩ | ⟨j', at_j', _, _⟩
      · rcases assignFields_source lenVos i o xs_i with ⟨_, oldO⟩ | ⟨j'', at_j'', _, _⟩
        · obtain ⟨paired, described, observed, allocated, tagsF, chainsF, deep, shapeA, _⟩ :=
            keptFacts i notIn w a o t oldW oldA oldO ts_i
          exact ⟨paired, described, observed, allocated, tagsF, chainsF, deep, shapeA,
            kindedFields i t w ts_i oldW, keptApart i notIn w oldW⟩
        · exact absurd (List.mem_of_getElem? at_j'') notIn
      · exact absurd (List.mem_of_getElem? at_j') notIn
    · rcases assignFields_source lenVabs i a fs_i with ⟨notIn, _⟩ | ⟨j', at_j', vabs_j', last'⟩
      · exact absurd (List.mem_of_getElem? at_j) notIn
      · have same := last_write_unique at_j last at_j' last'
        subst same
        rcases assignFields_source lenVos i o xs_i with ⟨notIn, _⟩ | ⟨j'', at_j'', vos_j'', last''⟩
        · exact absurd (List.mem_of_getElem? at_j) notIn
        · have same := last_write_unique at_j last at_j'' last''
          subst same
          obtain ⟨t', ts_f, us_j⟩ := newType j i at_j
          rw [ts_i] at ts_f
          cases ts_f
          obtain ⟨paired, described, observed, _, _, shapeA, allocated, tagsF, chainsF, deep⟩ :=
            valFacts j o w a t vos_j'' vws_j vabs_j' us_j
          exact ⟨paired, described, observed, allocated, tagsF, chainsF, deep, shapeA,
            kinded_atoms inv state valuesTypedList covValues heapVals j w t vws_j us_j, newApart j w vws_j⟩
  have fieldWitness : ∀ (i : Nat) w, ws'[i]? = some w → ∃ a o t, fs'[i]? = some a ∧ xs'[i]? = some o ∧
      ts[i]? = some t := by
    intro i w ws_i
    obtain ⟨t, ts_i⟩ := index_of_same_length lenW' ws_i
    obtain ⟨a, fs_i⟩ := index_of_same_length lenF'.symm ts_i
    obtain ⟨o, xs_i⟩ := index_of_same_length lenX'.symm ts_i
    exact ⟨a, o, t, fs_i, xs_i, ts_i⟩
  -- the write
  have lt : c < hs.heap.size := (Array.getElem?_eq_some_iff.mp slot).1
  have slotNew : (hs.heap.set! c [.record ws'])[c]? = some [.record ws'] := by simp [lt]
  have agree : ∀ (i : Nat) w, ws'[i]? = some w → ∀ d, Reaches hs.heap w (.ref d) →
      (hs.heap.set! c [.record ws'])[d]? = hs.heap[d]? := by
    intro i w ws_i d reach
    obtain ⟨a, o, t, fs_i, xs_i, ts_i⟩ := fieldWitness i w ws_i
    have apart := (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.2.2.2.2.2
    refine lookup_set_other hs.heap c _ (fun same => ?_)
    subst same
    exact apart reach
  have keptsAt : ∀ g, g ∉ written → ∀ w, ws[g]? = some w → ws'[g]? = some w := fun g notIn w ws_g => by
    rw [keptSame g notIn]; exact ws_g
  -- the heap typing after the write
  have kindedNew : Kinded kinds (.record ts) (.record ws') := .record ts ws' lenW' (fun i t w ts_i ws_i => by
    obtain ⟨a, o, t', fs_i, xs_i, ts_i'⟩ := fieldWitness i w ws_i
    rw [ts_i] at ts_i'
    cases ts_i'
    exact (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.2.2.2.2.1)
  -- the certificate of the old object over its live fields, and where each field of the result comes from
  have cert : ObjectCert hs.heap c ws ex (fun g => (k, p0 ++ [.element, .field g]) ∈ live) :=
    inv.objectsCertified k o0 w0 a0 p0 c cs (.record fs) ex ws binding abstractBinding p0Fields projQ atQ slot
  have repOf : ∀ {o : Observation} {w : Value}, Corresponds hs.heap o w → ∃ n o' fp, Represents hs.heap n w o' fp :=
    fun paired => by
      obtain ⟨_, rep⟩ := represents_of_snapshot _ _ _ (paired _ (Nat.le_refl _))
      exact ⟨_, _, _, rep⟩
  have keptAt : ∀ (i : Nat) w, i ∉ written → ws[i]? = some w → ∃ a t o, fs[i]? = some a ∧ FlatAbstract t a ∧
      Describes gamma hs.heap (entryAbstract declarations t a) w ∧ AllocatedFlatValue hs.heap w (entryType t) ∧
      Corresponds hs.heap o w ∧ (k, p0 ++ [.element, .field i]) ∈ live := by
    intro i w notIn ws_i
    obtain ⟨t, ts_i⟩ := index_of_same_length lenW ws_i
    obtain ⟨a, fs_i⟩ := index_of_same_length lenF ts_i
    obtain ⟨o, xs_i⟩ := index_of_same_length (lenW.trans lenX.symm) ws_i
    obtain ⟨paired, described, _, allocated, _, _, _, shapeA, use⟩ := keptFacts i notIn w a o t ws_i fs_i xs_i ts_i
    exact ⟨a, t, o, fs_i, shapeA, described, allocated, paired, use⟩
  have newAt : ∀ (j : Nat) w, vws[j]? = some w → ∃ a t, vabs[j]? = some a ∧ FlatAbstract t a ∧
      Describes gamma hs.heap (entryAbstract declarations t a) w ∧ AllocatedFlatValue hs.heap w (entryType t) := by
    intro j w vws_j
    obtain ⟨f, at_f⟩ := index_of_same_length (lenVW.trans (List.length_map _)) vws_j
    obtain ⟨t, ts_f, us_j⟩ := newType j f at_f
    obtain ⟨o, vos_j⟩ := index_of_same_length (lenVW.trans lenVO.symm) vws_j
    obtain ⟨a, vabs_j⟩ := index_of_same_length (lenVW.trans lenVA.symm) vws_j
    obtain ⟨_, described, _, _, _, shapeA, allocated, _⟩ := valFacts j o w a t vos_j vws_j vabs_j us_j
    exact ⟨a, t, vabs_j, shapeA, described, allocated⟩
  have source : ∀ (i : Nat) w, ws'[i]? = some w →
      (i ∉ written ∧ ws[i]? = some w) ∨
      ∃ j : Nat, written[j]? = some i ∧ vws[j]? = some w ∧ ∀ j' : Nat, j < j' → written[j']? ≠ some i := by
    intro i w ws_i
    rw [ws'Def] at ws_i
    exact assignFields_source lenVws i w ws_i
  have positionsApart : ∀ {i i' j j' : Nat}, i ≠ i' → written[j]? = some i → written[j']? = some i' → j ≠ j' :=
    fun ne at_j at_j' same => ne (by subst same; rw [at_j] at at_j'; exact Option.some.inj at_j')
  have cApartNew : ∀ w ∈ ws', ¬ Reaches (hs.heap.set! c [.record ws']) w (.ref c) := by
    intro w member reach
    obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨a, o, t, fs_i, xs_i, ts_i⟩ := fieldWitness i w ws_i
    exact (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.2.2.2.2.2 (reaches_of_agree_rev (agree i w ws_i) reach)
  have heapFuelOf : vs.fuel ≠ 0 → hs.fuel ≠ 0 := fun h => by simpa only [← inv.fuel] using h
  constructor
  · intro value vs' run
    rw [value_assign_success vs (valueEnv env) valueBase valueVals] at run
    by_cases noDepth : depth = 0
    · simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · simp [noDepth, noFuel] at run
      · rw [value_observeKept_run (valueTicked vs) represented] at run
        simp only [noDepth, noFuel, if_false, bind, Except.bind, pure, Except.pure, Except.ok.injEq,
          Prod.mk.injEq] at run
        obtain ⟨rfl, rfl⟩ := run
        rw [← xs'Def]
        -- the in-place run
        have heapRun := heap_assign_success (depth := depth) (declarations := declarations) (width := width)
          (fields := written) hs (heapEnv env) heapBase heapVals slot unlinked
        rw [← ws'Def] at heapRun
        have observersAfter : RepresentsMany (heapAssigned hs c [.record ws] [.record ws']).heap observationDepth
            (heapAssigned hs c [.record ws] [.record ws']).kept.toList vs.kept.toList footprint :=
          representsMany_after_write represented rootOutside
        rw [heap_observeKept_run _ observersAfter] at heapRun
        simp only [noDepth, heapFuelOf noFuel, if_false, bind, Except.bind, pure, Except.pure] at heapRun
        have heapEq : (heapObserved (heapAssigned hs c [.record ws] [.record ws']) vs.kept.toList).heap =
            hs.heap.set! c [.record ws'] := by rw [heapObserved_heap]; rfl
        have linksEq : (heapObserved (heapAssigned hs c [.record ws] [.record ws']) vs.kept.toList).links =
            hs.links := by rw [heapObserved_links]; rfl
        have state' : StateKinded kinds (heapObserved (heapAssigned hs c [.record ws] [.record ws']) vs.kept.toList)
            env tenv :=
          state.of_write kindC (ContentsKinded.object ts (.record ws') kindedNew) heapEq linksEq
        have postInvariant := flatInvariant_heap_frame inv (inside := (· = c)) (footprint := footprint) afterSub
          (by rw [heapEq]; simp)
          (Ownership.LinkClauses.linksValid_of_same
            (Ownership.LinkClauses.linksValid_set inv.toInvariant.linksValid c _ unlinked) (by rw [heapEq]) linksEq)
          (by rw [linksEq]; exact inv.linkClosed)
          (fun d different => by rw [heapEq]; exact lookup_set_other hs.heap c _ different)
          (assign_live_apart inv scope afterSub cNamed deadSep)
          (assign_projected inv afterSub heapEq slot keptSame (assign_route inv scope afterSub cNamed deadSep))
          represented (fun d member same => rootOutside (same ▸ member))
          (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) (fun _ _ _ => Iff.rfl)
          (by rw [heapEq]; simpa using inv.namingBound) inv.separating
          (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapAssigned hs c [.record ws] [.record ws']) inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapAssigned, inv.fuel])
          (fun _ escaped => escaped) ⟨kinds, state'⟩
        have pairedSlot : Corresponds (hs.heap.set! c [.record ws']) (.record xs') (.record ws') :=
          corresponds_record_of_fields (lenX'.trans lenW'.symm) (fun i o w xs_i ws_i => by
            obtain ⟨a, o', t, fs_i, xs_i', ts_i⟩ := fieldWitness i w ws_i
            rw [xs_i] at xs_i'
            cases xs_i'
            exact corresponds_of_agree (agree i w ws_i) (fieldFacts i w a o t ws_i fs_i xs_i ts_i).1)
        have pairedNew : Corresponds (hs.heap.set! c [.record ws']) (.list [.record xs']) (.ref c) :=
          corresponds_list_of_elements slotNew rfl (fun i o w os_i ws_i => by
            cases i with
            | zero =>
              simp only [List.getElem?_cons_zero, Option.some.injEq] at os_i ws_i
              subst os_i; subst ws_i
              exact pairedSlot
            | succ i => simp at os_i)
        have observedNew : obsTyped declarations (.list [.record xs']) (.object ts) = true :=
          obsTyped_object_of_slot (obsTyped_record_of_fields lenX' (fun i o t xs_i ts_i => by
            obtain ⟨w, ws_i⟩ := index_of_same_length (lenX'.trans lenW'.symm) xs_i
            obtain ⟨a, o', t', fs_i, xs_i', ts_i'⟩ := fieldWitness i w ws_i
            rw [xs_i] at xs_i'
            cases xs_i'
            rw [ts_i] at ts_i'
            cases ts_i'
            exact (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.1))
        have slotShape : AllocatedFlatValue (hs.heap.set! c [.record ws']) (.record ws') (entryType (.record ts)) :=
          .record ws' (entryTypes ts) (by rw [entryTypes_length]; exact lenW') (fun i w t' ws_i types_i => by
            obtain ⟨t, ts_i, rfl⟩ := entryTypes_index_inv types_i
            obtain ⟨a, o, t'', fs_i, xs_i, ts_i'⟩ := fieldWitness i w ws_i
            rw [ts_i] at ts_i'
            cases ts_i'
            exact allocated_of_agree (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.1 (agree i w ws_i))
        have shapedNew : AllocatedFlatValue (hs.heap.set! c [.record ws']) (.ref c) (entryType (.object ts)) :=
          .object c (.record ws') (entryTypes ts) slotNew slotShape
        have describedSlot : Describes gamma (hs.heap.set! c [.record ws'])
            (entryAbstract declarations (.record ts) (.record fs')) (.record ws') := by
          refine describes_record_of_fields (by rw [entryFields_length]; exact lenF'.trans lenW'.symm) ?_
          intro i a' w as_i ws_i
          obtain ⟨a, fs_i, rfl⟩ := entryFields_index_inv as_i
          obtain ⟨a'', o, t, fs_i', xs_i, ts_i⟩ := fieldWitness i w ws_i
          rw [fs_i] at fs_i'
          cases fs_i'
          rw [ts_i]
          exact describes_of_agree (agree i w ws_i) (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.1
        have tagsSlot : ElementTags (hs.heap.set! c [.record ws']) (entryType (.record ts))
            (entryAbstract declarations (.record ts) (.record fs')) (.record ws') := by
          refine ⟨.record (entryTypes ts) (entryFields declarations ts fs') ws'
              (by rw [entryTypes_length, entryFields_length]; exact lenF'.symm) ?_, ?_, ?_⟩
          · intro i t' a' w types_i as_i ws_i
            obtain ⟨t, ts_i, rfl⟩ := entryTypes_index_inv types_i
            obtain ⟨a, fs_i, rfl⟩ := entryFields_index_inv as_i
            obtain ⟨a'', o, t'', fs_i', xs_i, ts_i'⟩ := fieldWitness i w ws_i
            rw [fs_i] at fs_i'
            cases fs_i'
            rw [ts_i] at ts_i' ⊢
            cases ts_i'
            exact (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.1
          · intro o' paired'
            have same := Ownership.FlatFragment.Shared.corresponds_unique paired' pairedSlot
            subst same
            refine .record (entryTypes ts) (entryFields declarations ts fs') xs'
              (by rw [entryTypes_length, entryFields_length]; exact lenF'.symm) ?_
            intro i t' a' o types_i as_i xs_i
            obtain ⟨t, ts_i, rfl⟩ := entryTypes_index_inv types_i
            obtain ⟨a, fs_i, rfl⟩ := entryFields_index_inv as_i
            obtain ⟨w, ws_i⟩ := index_of_same_length (lenX'.trans lenW'.symm) xs_i
            obtain ⟨a'', o'', t'', fs_i', xs_i', ts_i'⟩ := fieldWitness i w ws_i
            rw [fs_i] at fs_i'
            cases fs_i'
            rw [xs_i] at xs_i'
            cases xs_i'
            rw [ts_i] at ts_i' ⊢
            cases ts_i'
            exact (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.2.1
          · refine .record (entryTypes ts) (entryFields declarations ts fs') ws'
              (by rw [entryTypes_length, entryFields_length]; exact lenF'.symm) ?_
            intro i t' a' w types_i as_i ws_i
            obtain ⟨t, ts_i, rfl⟩ := entryTypes_index_inv types_i
            obtain ⟨a, fs_i, rfl⟩ := entryFields_index_inv as_i
            obtain ⟨a'', o, t'', fs_i', xs_i, ts_i'⟩ := fieldWitness i w ws_i
            rw [fs_i] at fs_i'
            cases fs_i'
            rw [ts_i] at ts_i' ⊢
            cases ts_i'
            exact tagsDeep_of_agree (fieldFacts i w a o t ws_i fs_i xs_i ts_i).2.2.2.2.2.2.1 (agree i w ws_i)
        have resultRep : entryAbstract declarations (.object ts) result =
            .list cs (entryAbstract declarations (.record ts) (.record fs'))
              ⟨ex.deep && storeExclusive {ctx with escaped := union ctx.escaped before.facts.escapes} vabs
                  (union (liveCellsWith ctx.config aenv after) ctx.pinned) (cellsOf (assignKept written fs)),
                ex.spine && storeSpines {ctx with escaped := union ctx.escaped before.facts.escapes} vabs
                    (union (liveCellsWith ctx.config aenv after) ctx.pinned) (cellsOf (assignKept written fs)) &&
                  ((assignKept written fs).flatMap containers).all
                    (fun (_, old) => individuallyOwned {ctx with escaped := union ctx.escaped before.facts.escapes} old &&
                      !cellOverlap old (cellsOf vabs))⟩ := by
          rw [resultEq, fs'Def]; rfl
        refine ⟨.ref c, heapObserved (heapAssigned hs c [.record ws] [.record ws']) vs.kept.toList, gamma, heapRun,
          by rw [nextEscapes]; exact postInvariant, by rw [heapEq]; simp, by rw [heapEq]; exact pairedNew, ?_,
          observedNew, by rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew,
          by rw [heapEq]; exact shapedNew, by rw [resultRep]; exact .object _ _ _ _ _, by rw [resultRep]; exact .object _ _ _,
          ?_, ⟨kinds, state', .object ts c kindC⟩⟩
        · rw [heapEq, resultRep]
          refine list_described_of_elements cNamed noUnk slotNew shapedNew (fun y member => by
            simp only [List.mem_singleton] at member
            subst member
            exact describedSlot) ?_ ?_
          · intro d
            simp only [Bool.and_eq_true] at d
            obtain ⟨exDeep, store⟩ := d
            obtain ⟨_, sepVals, _⟩ := storeExclusive_facts_many store
            obtain ⟨_, cross⟩ := separatedValues_sound sepVals
            have newFacts : ∀ (j : Nat) w, vws[j]? = some w → ∃ a t, vabs[j]? = some a ∧ FlatAbstract t a ∧
                Describes gamma hs.heap (entryAbstract declarations t a) w ∧
                (∀ n o fp, Represents hs.heap n w o fp → fp.Nodup) ∧
                ∀ b ∈ assignKept written fs, cellOverlap (entryAbstract declarations t a).cells b.cells = false := by
              intro j w vws_j
              obtain ⟨a, t, vabs_j, shapeA, described, allocated⟩ := newAt j w vws_j
              have single := storeExclusive_single store (List.mem_of_getElem? vabs_j)
              rw [← storeExclusive_entry (ds := declarations) (t := t) (as := [a])
                (fun b member => by simp only [List.mem_singleton] at member; subst member; exact shapeA) _ _ false]
                at single
              simp only [List.map_cons, List.map_nil] at single
              obtain ⟨deepE, sepE, overlapE⟩ := storeExclusive_facts single
              refine ⟨a, t, vabs_j, shapeA, described,
                nodup_of_deepExclusive allocated (flatAbstract_entry shapeA) described deepE
                  (pathsApart_of_separated inv.separating sepE), fun b member => ?_⟩
              exact cellOverlap_false_of_subset overlapE (fun o m => mem_union_right_of (mem_cellsOf member m))
            refine slot_footprint_nodup slotNew cApartNew (fun i w ws_i n o fp rep => ?_)
              (fun i i' ne wi wi' ws_i ws_i' d reachI reachI' => ?_)
            · have rep' := represents_of_agree_rev (agree i w ws_i) rep
              rcases source i w ws_i with ⟨notIn, ws_i0⟩ | ⟨j, _, vws_j, _⟩
              · obtain ⟨_, _, _, _, _, _, _, _, use⟩ := keptAt i w notIn ws_i0
                exact (List.nodup_cons.mp ((objectCert_single cert use ws_i0 rep').1 exDeep)).2
              · obtain ⟨_, _, _, _, _, nodup, _⟩ := newFacts j w vws_j
                exact nodup n o fp rep'
            · have r1 := reaches_of_agree_rev (agree i wi ws_i) reachI
              have r2 := reaches_of_agree_rev (agree i' wi' ws_i') reachI'
              rcases source i wi ws_i with ⟨notIn, ws_i0⟩ | ⟨j, at_j, vws_j, _⟩ <;>
                rcases source i' wi' ws_i' with ⟨notIn', ws_i0'⟩ | ⟨j', at_j', vws_j', _⟩
              · obtain ⟨_, _, _, _, _, _, _, paired, use⟩ := keptAt i wi notIn ws_i0
                obtain ⟨_, _, _, _, _, _, _, paired', use'⟩ := keptAt i' wi' notIn' ws_i0'
                exact (objectCert_pair cert ne use use' ws_i0 ws_i0' (repOf paired) (repOf paired')).1 exDeep d r1 r2
              · obtain ⟨b, tb, _, fs_i, shapeB, describedB, _, _, _⟩ := keptAt i wi notIn ws_i0
                obtain ⟨a, t, _, shapeA, described, _, overlap⟩ := newFacts j' wi' vws_j'
                have disjoint := overlap b (mem_assignKept fs_i notIn)
                rw [← cells_entryAbstract (ds := declarations) shapeB] at disjoint
                exact reach_apart_of_covers inv.separating (flatAbstract_entry shapeA) (flatAbstract_entry shapeB)
                  described.1.1 describedB.1.1 disjoint d r2 r1
              · obtain ⟨b, tb, _, fs_i, shapeB, describedB, _, _, _⟩ := keptAt i' wi' notIn' ws_i0'
                obtain ⟨a, t, _, shapeA, described, _, overlap⟩ := newFacts j wi vws_j
                have disjoint := overlap b (mem_assignKept fs_i notIn')
                rw [← cells_entryAbstract (ds := declarations) shapeB] at disjoint
                exact reach_apart_of_covers inv.separating (flatAbstract_entry shapeA) (flatAbstract_entry shapeB)
                  described.1.1 describedB.1.1 disjoint d r1 r2
              · obtain ⟨a, t, vabs_j, shapeA, described, _, _⟩ := newFacts j wi vws_j
                obtain ⟨a', t', vabs_j', shapeA', described', _, _⟩ := newFacts j' wi' vws_j'
                rcases Nat.lt_or_gt_of_ne (positionsApart ne at_j at_j') with lt | gt
                · have disjoint := cross j j' lt a a' vabs_j vabs_j'
                  rw [← cells_entryAbstract (ds := declarations) shapeA,
                    ← cells_entryAbstract (ds := declarations) shapeA'] at disjoint
                  exact reach_apart_of_covers inv.separating (flatAbstract_entry shapeA) (flatAbstract_entry shapeA')
                    described.1.1 described'.1.1 disjoint d r1 r2
                · have disjoint := cross j' j gt a' a vabs_j' vabs_j
                  rw [← cells_entryAbstract (ds := declarations) shapeA,
                    ← cells_entryAbstract (ds := declarations) shapeA'] at disjoint
                  exact reach_apart_of_covers inv.separating (flatAbstract_entry shapeA') (flatAbstract_entry shapeA)
                    described'.1.1 described.1.1 disjoint d r2 r1
          · intro sp
            simp only [Bool.and_eq_true] at sp
            obtain ⟨⟨exSpine, spines⟩, keptCheck⟩ := sp
            obtain ⟨sepFlat, perItem⟩ := storeSpines_facts_many spines
            have keptContainers : ∀ b ∈ assignKept written fs, ∀ e ∈ containers b,
                cellOverlap e.2 (cellsOf vabs) = false := by
              intro b bMember e eMember
              have h := List.all_eq_true.mp keptCheck e (List.mem_flatMap.mpr ⟨b, bMember, eMember⟩)
              obtain ⟨p, cs'⟩ := e
              simp only [Bool.and_eq_true, Bool.not_eq_true'] at h
              exact h.2
            have newFacts : ∀ (j : Nat) w, vws[j]? = some w → ∃ a t, vabs[j]? = some a ∧ FlatAbstract t a ∧
                Describes gamma hs.heap (entryAbstract declarations t a) w ∧
                AllocatedFlatValue hs.heap w (entryType t) ∧
                (∀ n o fp, Represents hs.heap n w o fp →
                  ∀ p d, containerPath p = true → ArrayAt hs.heap w p d → fp.count d = 1) ∧
                ∀ e ∈ containers (entryAbstract declarations t a), ∀ b ∈ assignKept written fs,
                  cellOverlap e.2 b.cells = false := by
              intro j w vws_j
              obtain ⟨a, t, vabs_j, shapeA, described, allocated⟩ := newAt j w vws_j
              have single := storeSpines_single spines (List.mem_of_getElem? vabs_j)
              rw [← storeSpines_entry (ds := declarations) (t := t) (as := [a])
                (fun b member => by simp only [List.mem_singleton] at member; subst member; exact shapeA) _ _]
                at single
              simp only [List.map_cons, List.map_nil] at single
              refine ⟨a, t, vabs_j, shapeA, described, allocated,
                once_of_storeSpines inv.separating (flatAbstract_entry shapeA) allocated described.1.1 single, ?_⟩
              obtain ⟨_, each⟩ := storeSpines_facts single
              intro e eMember b bMember
              exact cellOverlap_false_of_subset (each e eMember).1
                (fun o m => mem_union_right_of (mem_cellsOf bMember m))
            refine slot_footprint_once slotNew cApartNew (fun i w ws_i n o fp rep p d container located => ?_)
              (fun i i' ne wi wi' ws_i ws_i' p d container located reachI' => ?_)
            · have rep' := represents_of_agree_rev (agree i w ws_i) rep
              have located' := atPath_of_agree_rev (agree i w ws_i) located
              rcases source i w ws_i with ⟨notIn, ws_i0⟩ | ⟨j, _, vws_j, _⟩
              · obtain ⟨_, _, _, _, _, _, _, _, use⟩ := keptAt i w notIn ws_i0
                have once := (objectCert_single cert use ws_i0 rep').2 exSpine p d container located'
                have ne : c ≠ d := fun same => keptApart i notIn w ws_i0 (same ▸ reaches_of_atPath located')
                simpa [List.count_cons, ne] using once
              · obtain ⟨_, _, _, _, _, _, once, _⟩ := newFacts j w vws_j
                exact once n o fp rep' p d container located'
            · have located' := atPath_of_agree_rev (agree i wi ws_i) located
              have r2 := reaches_of_agree_rev (agree i' wi' ws_i') reachI'
              rcases source i wi ws_i with ⟨notIn, ws_i0⟩ | ⟨j, at_j, vws_j, _⟩ <;>
                rcases source i' wi' ws_i' with ⟨notIn', ws_i0'⟩ | ⟨j', at_j', vws_j', _⟩
              · obtain ⟨_, _, _, _, _, _, _, paired, use⟩ := keptAt i wi notIn ws_i0
                obtain ⟨_, _, _, _, _, _, _, paired', use'⟩ := keptAt i' wi' notIn' ws_i0'
                exact (objectCert_pair cert ne use use' ws_i0 ws_i0' (repOf paired) (repOf paired')).2 exSpine
                  p d container located' r2
              · obtain ⟨b, tb, _, fs_i, shapeB, describedB, allocatedB, _, _⟩ := keptAt i wi notIn ws_i0
                obtain ⟨a, t, vabs_j', shapeA, described, _, _, _⟩ := newFacts j' wi' vws_j'
                obtain ⟨oK, mK, adK⟩ := describedB.1.1 p d located'
                obtain ⟨cs', eK, inK⟩ :=
                  mem_namesAt_of_arrayAt (flatAbstract_entry shapeB) allocatedB p d oK located' mK
                obtain ⟨p', cK⟩ := containers_entry_mem shapeB (List.mem_filter.mpr ⟨eK, container⟩)
                have disjoint := keptContainers b (mem_assignKept fs_i notIn) (p', cs') cK
                obtain ⟨q, locatedN⟩ := arrayAt_of_reaches r2
                have namedN := named_cells_of_covers (flatAbstract_entry shapeA) described.1.1 locatedN
                rw [cells_entryAbstract shapeA] at namedN
                exact cellOverlap_sound gamma inv.separating cs' (cellsOf vabs) disjoint d ⟨oK, inK, adK⟩
                  (named_of_subset namedN (fun o m => mem_cellsOf (List.mem_of_getElem? vabs_j') m))
              · obtain ⟨b, tb, _, fs_i, shapeB, describedB, _, _, _⟩ := keptAt i' wi' notIn' ws_i0'
                obtain ⟨a, t, _, shapeA, described, allocated, _, overlap⟩ := newFacts j wi vws_j
                obtain ⟨oN, mN, adN⟩ := described.1.1 p d located'
                obtain ⟨cs', eN, inN⟩ :=
                  mem_namesAt_of_arrayAt (flatAbstract_entry shapeA) allocated p d oN located' mN
                have disjoint := overlap (p, cs') (List.mem_filter.mpr ⟨eN, container⟩) b (mem_assignKept fs_i notIn')
                obtain ⟨q, locatedK⟩ := arrayAt_of_reaches r2
                have namedK := named_cells_of_covers (flatAbstract_entry shapeB) describedB.1.1 locatedK
                rw [cells_entryAbstract shapeB] at namedK
                exact cellOverlap_sound gamma inv.separating cs' b.cells disjoint d ⟨oN, inN, adN⟩ namedK
              · obtain ⟨aI, tI, vabs_j, shapeI, describedI, allocatedI, _, _⟩ := newFacts j wi vws_j
                obtain ⟨aJ, tJ, vabs_j', shapeJ, describedJ, allocatedJ, _, _⟩ := newFacts j' wi' vws_j'
                obtain ⟨oI, mI, adI⟩ := describedI.1.1 p d located'
                obtain ⟨q, locatedJ⟩ := arrayAt_of_reaches r2
                obtain ⟨oJ, mJ, adJ⟩ := describedJ.1.1 q d locatedJ
                obtain ⟨cs', eI, inI⟩ :=
                  mem_namesAt_of_arrayAt (flatAbstract_entry shapeI) allocatedI p d oI located' mI
                obtain ⟨ds', eJ, inJ⟩ :=
                  mem_namesAt_of_arrayAt (flatAbstract_entry shapeJ) allocatedJ q d oJ locatedJ mJ
                obtain ⟨p', cI⟩ := containers_entry_mem shapeI (List.mem_filter.mpr ⟨eI, container⟩)
                obtain ⟨q', eJ', _⟩ := paths_entry_mem shapeJ eJ
                rcases (perItem aI (List.mem_of_getElem? vabs_j) (p', cs') cI).2 aJ (List.mem_of_getElem? vabs_j')
                    (q', ds') eJ' with containerQ | disjoint
                · have cJ : (q', ds') ∈ containers aJ := List.mem_filter.mpr ⟨eJ', containerQ⟩
                  rcases Nat.lt_or_gt_of_ne (positionsApart ne at_j at_j') with lt | gt
                  · exact cellOverlap_sound gamma inv.separating cs' ds'
                      (separatedPaths_flatMap_cross sepFlat j j' lt aI aJ vabs_j vabs_j' (p', cs') cI (q', ds') cJ) d
                      ⟨oI, inI, adI⟩ ⟨oJ, inJ, adJ⟩
                  · exact cellOverlap_sound gamma inv.separating ds' cs'
                      (separatedPaths_flatMap_cross sepFlat j' j gt aJ aI vabs_j' vabs_j (q', ds') cJ (p', cs') cI) d
                      ⟨oJ, inJ, adJ⟩ ⟨oI, inI, adI⟩
                · exact cellOverlap_sound gamma inv.separating cs' ds' disjoint d ⟨oI, inI, adI⟩ ⟨oJ, inJ, adJ⟩
        · rw [heapEq, resultRep]
          exact .object c [.record ws'] (entryTypes ts) cs _ _ slotNew
            (fun w member => by simp only [List.mem_singleton] at member; subst member; exact tagsSlot.1)
            (fun w member => by simp only [List.mem_singleton] at member; subst member; exact tagsSlot.2.1)
            (fun w member => by simp only [List.mem_singleton] at member; subst member; exact tagsSlot.2.2)
  · intro message failed
    rw [value_assign_success vs (valueEnv env) valueBase valueVals] at failed
    have heapRun := heap_assign_success (depth := depth) (declarations := declarations) (width := width)
      (fields := written) hs (heapEnv env) heapBase heapVals slot unlinked
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by rw [heapRun]; simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by rw [heapRun]; simp [noDepth, heapFuel]⟩
      · rw [value_observeKept_run (valueTicked vs) represented] at failed
        simp [noDepth, noFuel, bind, Except.bind, pure, Except.pure] at failed

end Ownership.FlatFragment.Objects
