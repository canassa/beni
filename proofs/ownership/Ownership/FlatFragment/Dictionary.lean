import Ownership.FlatFragment.ChainCase

/-! The first flat fragment: the dictionary forms (#522, slice 3).

A dictionary of `t` is its entries in insertion order, each the record
`[Int k, v]` (`Semantics.lean`, `dictPut`). The checker describes it as a list
whose element is the value's abstract; the relation reads it through its
representation, a list of entry records (`entryType`, `entryAbstract`, #1796).
So each dictionary form is a list form on the entries: the size is a length,
the empty dictionary a fresh empty array, a lookup an element read, an insert
a push or an in-place set of one entry, a remove a filter of the entries. A
dictionary's value can be any flat type, a dictionary too (#1840): each case
reads the value at its representation, and the checker's store tests on the
value give the same answers there (`entryAbstract_stored_dict`). -/

namespace Ownership.FlatFragment.Dictionary

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Push
open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.ListPrimitives Ownership.FlatFragment.Let

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The entries of a dictionary-typed atom -/

/-- A dictionary's observation is typed as the list of its entry records. -/
theorem obsTyped_dict_elements {ds : List Decl} {os : List Observation} {t : Ty}
    (typed : obsTyped ds (.list os) (.dict t) = true) : ∀ o ∈ os, obsTyped ds o (.record [.int, t]) = true := by
  unfold obsTyped at typed
  change os.attach.all (fun item => obsTyped ds item.val (.record [.int, t])) = true at typed
  intro o member
  exact List.all_eq_true.mp typed ⟨o, member⟩ (List.mem_attach _ _)

/-- The entry record's type is flat, and its abstract is a flat abstract of it. -/
theorem flatType_entry {t : Ty} (flat : FlatType t) : FlatType (.record [.int, t]) := by
  refine .record _ ?_
  intro t' member
  simp only [List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with rfl | rfl
  · exact .int
  · exact flat

theorem flatAbstract_entryRecord {t : Ty} {value : Abstract} (shape : FlatAbstract t value) :
    FlatAbstract (.record [.int, t]) (.record [.scalar, value]) := by
  refine .record _ _ rfl ?_
  intro i t' a' ht ha
  match i, ht, ha with
  | 0, ht, ha =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at ht ha
    subst ht; subst ha
    exact .int
  | 1, ht, ha =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ht ha
    subst ht; subst ha
    exact shape
  | _ + 2, ht, _ => simp at ht

/-- A `Dict t`-typed atom whose uses are live: an allocated array of entry
records on the heap side, the list of their observations on the value side,
and a named flat dictionary in the checker, read through its representation:
an entry is a record of the key and the value's representation (#1796,
#1840). -/
theorem flat_atom_dict_path {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {atom : Atom} {t : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (typed : atomType tenv atom = .ok (.dict t))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (root : Nat) (ys : List Value) (os : List Observation) (roots : List Origin) (value : Abstract)
      (certificate : Certificate),
      hs.heap[root]? = some ys ∧
      named gamma roots root ∧ Origin.unknown ∉ roots ∧
      FlatType t ∧
      (∀ y ∈ ys, ResultTags (.record [.int, entryType t]) (.record [.scalar, entryAbstract declarations t value]) y ∧
        (∀ o, Corresponds hs.heap o y →
          ChainTags (.record [.int, entryType t]) (.record [.scalar, entryAbstract declarations t value]) o) ∧
        TagsDeep hs.heap (.record [.int, entryType t]) (.record [.scalar, entryAbstract declarations t value]) y) ∧
      FlatAbstract t value ∧
      (∀ y ∈ ys, AllocatedFlatValue hs.heap y (.record [.int, entryType t])) ∧
      (∀ y ∈ ys, Describes gamma hs.heap (.record [.scalar, entryAbstract declarations t value]) y) ∧
      os.length = ys.length ∧
      (∀ o ∈ os, obsTyped declarations o (.record [.int, t]) = true) ∧
      (∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds hs.heap o y) ∧
      Corresponds hs.heap (.list os) (.ref root) ∧
      Describes gamma hs.heap (.list roots (.record [.scalar, entryAbstract declarations t value]) certificate)
        (.ref root) ∧
      ValueSemantics.atom (valueEnv env) atom = .ok (.list os) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref root) ∧
      abstractAtom aenv atom = .ok (.list roots value certificate) := by
  obtain ⟨o, w, a, valueRun, heapRun, abstractRun, paired, described, observed, _, flatDict, shape, allocated,
    tags, _, deep⟩ := flat_atom_entry inv typed covered
  have flatT : FlatType t := by
    cases flatDict with
    | dict _ flatT => exact flatT
  rw [entryType_dict] at allocated tags deep
  cases shape with
  | bottom _ =>
    rw [entryAbstract_bottom] at tags
    cases tags
  | dict _ roots value certificate noUnk valueShape =>
    rw [entryAbstract_dict_list] at described tags deep
    cases allocated with
    | list root ys _ lookup elements =>
      obtain ⟨os, rfl, lenO, pointwise⟩ := corresponds_list_elements lookup paired
      have names := described.1.1 [] root (.here _)
      rw [list_root_names] at names
      exact ⟨root, ys, os, roots, value, certificate, lookup, named_union_nil names, noUnk,
        flatT, tagsDeep_elements deep lookup, valueShape,
        elements, fun y member => describes_element noUnk lookup member described, lenO,
        obsTyped_dict_elements observed, pointwise, paired,
        described, valueRun, heapRun, abstractRun⟩

/-! ### The size: the length of the entries -/

theorem value_dictSize_run (s : ValueSemantics.State) (os : List Observation) :
    (ValueSemantics.prim .dictSize [.list os]).run s =
      .ok (.int os.length, {s with reads := s.reads.push (.int os.length)}) := by
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, Observation.depth,
    observationDepth, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_dictSize_run (s : State) (ys : List Value)
    (lookup : s.heap[root]? = some ys) :
    (prim .dictSize [.ref root]).run s =
      .ok (.int ys.length, {s with reads := s.reads.push (.int ys.length)}) := by
  simp [prim, array, lookup, InPlaceSemantics.read, snapshot, observationDepth,
    Option.toExcept, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem dictSize_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {receiver : Atom} {escapes : List Origin}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueAtom : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapAtom : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys) (len : os.length = ys.length)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .dictSize [receiver])).run vs =
      .ok (.int os.length, valueRead vs (.int os.length)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .dictSize [receiver])).run hs =
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
    simp [hasDepth, hasFuel, valueTicked, value_dictSize_run, valueObservedRun, valueRead,
      Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_dictSize_run {hs with fuel := hs.fuel - 1} ys lookup, len,
      heapObservedRun, heapRead,
      Except.bind, Except.pure, bind, pure]

theorem dictSize_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {receiver : Atom} {self : Decl} {type : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .dictSize [receiver]) = .ok type)
    (covered : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .dictSize [receiver]) after site).run before =
      .ok (result, next)) :
    type = .int ∧ next.facts.escapes = before.facts.escapes ∧ result = .scalar ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .dictSize [receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .dictSize [receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value ∧ TagsDeep hs'.heap type result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .dictSize [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .dictSize [receiver])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, intType⟩ := exprType_dictSize_success (fun _ _ h => flat_atom_type inv h) typed
  subst intType
  obtain ⟨root, ys, os, roots, value, certificate, lookup, _, _, _, _, _, _, _, len, _, _, _, _,
    valueAtom, heapAtom, abstractReceiver⟩ := flat_atom_dict_path inv receiverTyped covered
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots value certificate] := except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_dictSize_run] at run
  have equal := Except.ok.inj run
  have resultScalar : result = .scalar := (congrArg Prod.fst equal).symm
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads ((Abstract.list roots value certificate).roots.filter external)}} :=
    (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  refine ⟨rfl, nextEscapes, resultScalar, ?_, ?_⟩
  · intro value' vs' run
    have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
        .ok [.list os] := except_mapM_cons valueAtom rfl
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          dictSize_runtime_success inv valueAtom heapAtom lookup len noDepth noFuel
        rw [valueRun] at run
        cases run
        refine ⟨.int os.length, heapRead hs (.int os.length) vs.kept.toList, gamma,
          heapRun, ?_, ?_, Ownership.FlatFragment.AtomPreservation.integer_corresponds _, ?_, by simp [obsTyped],
          ⟨1, .int os.length, [], .int, by simp [obsTyped]⟩, .int _, by rw [resultScalar]; exact .int _,
          .int _ _, .int _ _⟩
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
      · have success := (dictSize_runtime_success inv valueAtom heapAtom lookup len noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### Entries -/

/-- An entry of a dictionary of `t` is the record of an integer key and a
value of `t`. -/
theorem entry_shape {heap : Heap} {y : Value} {t : Ty} (shape : AllocatedFlatValue heap y (.record [.int, t])) :
    ∃ k v, y = .record [.int k, v] ∧ AllocatedFlatValue heap v t := by
  cases shape with
  | record ws _ len fields =>
    match ws, len with
    | [w0, w1], _ =>
      have first := fields 0 w0 .int rfl rfl
      cases first with
      | int k => exact ⟨k, w1, rfl, fields 1 w1 t rfl rfl⟩

/-- The observation of an entry is the record of its key and the observation
of its value. -/
theorem entry_corresponds {heap : Heap} {o : Observation} {k : Int} {v : Value}
    (paired : Corresponds heap o (.record [.int k, v])) :
    ∃ ov, o = .record [.int k, ov] ∧ Corresponds heap ov v := by
  obtain ⟨os, rfl, len, fields⟩ := corresponds_record_fields paired
  match os, len with
  | [o0, o1], _ =>
    have key := corresponds_int_inv (fields 0 o0 (.int k) rfl rfl)
    subst key
    exact ⟨o1, rfl, fields 1 o1 v rfl rfl⟩

/-- Both interpreters find the entry of a key at the same place: corresponding
entries have the same key. -/
theorem dictFind_corresponds {heap : Heap} (k : Int) :
    ∀ (os : List Observation) (ys : List Value), os.length = ys.length →
      (∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds heap o y) →
      (∀ y ∈ ys, ∃ k' v, y = .record [.int k', v]) →
      (dictFind ValueSemantics.entryKey os k = none ∧ dictFind InPlaceSemantics.entryKey ys k = none) ∨
      ∃ o y, dictFind ValueSemantics.entryKey os k = some o ∧ dictFind InPlaceSemantics.entryKey ys k = some y ∧
        y ∈ ys ∧ Corresponds heap o y
  | [], [], _, _, _ => Or.inl ⟨rfl, rfl⟩
  | o :: os, y :: ys, len, pointwise, entries => by
    obtain ⟨k', v, rfl⟩ := entries y (by simp)
    obtain ⟨ov, rfl, _⟩ := entry_corresponds (pointwise 0 o _ rfl rfl)
    by_cases same : k' = k
    · subst same
      exact Or.inr ⟨_, _, by simp [dictFind, ValueSemantics.entryKey],
        by simp [dictFind, InPlaceSemantics.entryKey], by simp, pointwise 0 _ _ rfl rfl⟩
    · have rest := dictFind_corresponds k os ys (by simpa using len)
        (fun i o' y' os_i ys_i => pointwise (i + 1) o' y' os_i ys_i)
        (fun y' member => entries y' (by simp [member]))
      have skipO : dictFind ValueSemantics.entryKey (.record [.int k', ov] :: os) k =
          dictFind ValueSemantics.entryKey os k := by
        simp [dictFind, ValueSemantics.entryKey, same]
      have skipV : dictFind InPlaceSemantics.entryKey (.record [.int k', v] :: ys) k =
          dictFind InPlaceSemantics.entryKey ys k := by
        simp [dictFind, InPlaceSemantics.entryKey, same]
      rw [skipO, skipV]
      rcases rest with none | ⟨o', y', foundO, foundV, member, paired⟩
      · exact Or.inl none
      · exact Or.inr ⟨o', y', foundO, foundV, by simp [member], paired⟩
  | [], _ :: _, len, _, _ => by simp at len
  | _ :: _, [], len, _, _ => by simp at len

/-! ### The lookup: the value of one entry -/

def getObs (os : List Observation) (k : Int) : Option Observation :=
  (dictFind ValueSemantics.entryKey os k).map ValueSemantics.entryValue

def getVal (ys : List Value) (k : Int) : Option Value :=
  (dictFind InPlaceSemantics.entryKey ys k).map InPlaceSemantics.entryValue

theorem value_dictGet_run (s : ValueSemantics.State) (os : List Observation) (k : Int)
    (shallow : ¬ ((getObs os k).getD (.int 0)).depth > observationDepth) :
    (ValueSemantics.prim .dictGet [.list os, .int k]).run s =
      .ok (ValueSemantics.maybe (getObs os k), {s with reads := s.reads.push ((getObs os k).getD (.int 0))}) := by
  unfold getObs at shallow ⊢
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, shallow, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
    pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem value_dictGet_run_deep (s : ValueSemantics.State) (os : List Observation) (k : Int)
    (deep : ((getObs os k).getD (.int 0)).depth > observationDepth) :
    (ValueSemantics.prim .dictGet [.list os, .int k]).run s = .error "snapshot exhausted depth" := by
  unfold getObs at deep
  simp [ValueSemantics.prim, ValueSemantics.read, ValueSemantics.observable, deep, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind,
    pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify,
    modifyGet, MonadStateOf.modifyGet, StateT.modifyGet, throw, throwThe, MonadExceptOf.throw, Except.error]

theorem heap_dictGet_run (s : State) (ys : List Value) (k : Int) {o : Observation}
    (lookup : s.heap[root]? = some ys)
    (snap : snapshot s.heap observationDepth ((getVal ys k).getD (.int 0)) = .ok o) :
    (prim .dictGet [.ref root, .int k]).run s =
      .ok (InPlaceSemantics.maybe (getVal ys k), {s with reads := s.reads.push o}) := by
  unfold getVal at snap ⊢
  simp [prim, array, lookup, InPlaceSemantics.read, snap, Option.toExcept, StateT.run, StateT.bind,
    StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get,
    getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify, modifyGet,
    MonadStateOf.modifyGet, StateT.modifyGet]

theorem heap_dictGet_run_deep (s : State) (ys : List Value) (k : Int) {e : String}
    (lookup : s.heap[root]? = some ys)
    (snap : snapshot s.heap observationDepth ((getVal ys k).getD (.int 0)) = .error e) :
    (prim .dictGet [.ref root, .int k]).run s = .error e := by
  unfold getVal at snap
  simp [prim, array, lookup, InPlaceSemantics.read, snap, Option.toExcept, StateT.run, StateT.bind,
    StateT.map, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get,
    getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, modify, modifyGet,
    MonadStateOf.modifyGet, StateT.modifyGet]

theorem dictGet_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver key : Atom} {os : List Observation} {ys : List Value} {root : Nat} {k : Int} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueKey : ValueSemantics.atom (valueEnv env) key = .ok (.int k))
    (heapKey : InPlaceSemantics.atom (heapEnv env) key = .ok (.int k))
    (lookup : hs.heap[root]? = some ys)
    (snap : snapshot hs.heap observationDepth ((getVal ys k).getD (.int 0)) = .ok ((getObs os k).getD (.int 0)))
    (shallow : ¬ ((getObs os k).getD (.int 0)).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .dictGet [receiver, key])).run vs =
      .ok (ValueSemantics.maybe (getObs os k), valueRead vs ((getObs os k).getD (.int 0))) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .dictGet [receiver, key])).run hs =
      .ok (InPlaceSemantics.maybe (getVal ys k), heapRead hs ((getObs os k).getD (.int 0)) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run
    ({vs with fuel := vs.fuel - 1, reads := vs.reads.push ((getObs os k).getD (.int 0))}) represented
  have heapObservedRun := heap_observeKept_run
    ({hs with fuel := hs.fuel - 1, reads := hs.reads.push ((getObs os k).getD (.int 0))}) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, key].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k] := except_mapM_cons valueReceiver (except_mapM_cons valueKey rfl)
  have heapAtoms : [receiver, key].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k] := except_mapM_cons heapReceiver (except_mapM_cons heapKey rfl)
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, valueTicked, value_dictGet_run {vs with fuel := vs.fuel - 1} os k shallow,
      valueObservedRun, valueRead, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heapTicked, heap_dictGet_run {hs with fuel := hs.fuel - 1} ys k lookup snap,
      heapObservedRun, heapRead, Except.bind, Except.pure, bind, pure]

theorem dictGet_runtime_deep {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver key : Atom} {os : List Observation} {ys : List Value} {root : Nat} {k : Int} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (heapKey : InPlaceSemantics.atom (heapEnv env) key = .ok (.int k))
    (lookup : hs.heap[root]? = some ys)
    (paired : Corresponds hs.heap ((getObs os k).getD (.int 0)) ((getVal ys k).getD (.int 0)))
    (deep : ((getObs os k).getD (.int 0)).depth > observationDepth)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    ∃ e, (InPlaceSemantics.eval depth declarations none (heapEnv env)
      (.prim .dictGet [receiver, key])).run hs = .error e := by
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have heapAtoms : [receiver, key].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k] := except_mapM_cons heapReceiver (except_mapM_cons heapKey rfl)
  obtain ⟨e, snapErr⟩ := Ownership.FlatFragment.Shared.snapshot_deep_error paired deep
  refine ⟨e, ?_⟩
  rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
  simp [hasDepth, heapFuel, heapTicked, heap_dictGet_run_deep {hs with fuel := hs.fuel - 1} ys k lookup snapErr,
    Except.bind, bind]

/-- What the lookup finds: nothing on either side, or one entry's value on
both, with its facts. -/
theorem dictGet_found {gamma : Naming} {heap : Heap} {t u : Ty} {value : Abstract} {declarations : List Decl}
    {os : List Observation} {ys : List Value} (k : Int)
    (lenO : os.length = ys.length)
    (pointwise : ∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds heap o y)
    (shaped : ∀ y ∈ ys, AllocatedFlatValue heap y (.record [.int, u]))
    (typedObs : ∀ o ∈ os, obsTyped declarations o (.record [.int, t]) = true)
    (described : ∀ y ∈ ys, Describes gamma heap (.record [.scalar, value]) y)
    (tags : ∀ y ∈ ys, ResultTags (.record [.int, u]) (.record [.scalar, value]) y ∧
      (∀ o, Corresponds heap o y → ChainTags (.record [.int, u]) (.record [.scalar, value]) o) ∧
      TagsDeep heap (.record [.int, u]) (.record [.scalar, value]) y) :
    (getObs os k = none ∧ getVal ys k = none) ∨
    ∃ ov v, getObs os k = some ov ∧ getVal ys k = some v ∧ Corresponds heap ov v ∧
      AllocatedFlatValue heap v u ∧ obsTyped declarations ov t = true ∧ Describes gamma heap value v ∧
      ResultTags u value v ∧ ChainTags u value ov ∧ TagsDeep heap u value v := by
  rcases dictFind_corresponds k os ys lenO pointwise
      (fun y member => by obtain ⟨k', v, rfl, _⟩ := entry_shape (shaped y member); exact ⟨k', v, rfl⟩) with
    ⟨noneO, noneV⟩ | ⟨o, y, foundO, foundV, member, paired⟩
  · exact Or.inl ⟨by simp [getObs, noneO], by simp [getVal, noneV]⟩
  · obtain ⟨k', v, rfl, allocatedV⟩ := entry_shape (shaped _ member)
    obtain ⟨ov, rfl, pairedV⟩ := entry_corresponds paired
    obtain ⟨tagsY, chainsY, deepY⟩ := tags _ member
    have memberO : Observation.record [.int k', ov] ∈ os := by
      have := List.mem_of_find?_eq_some foundO
      exact this
    have typedEntry := typedObs _ memberO
    refine Or.inr ⟨ov, v, by simp [getObs, foundO, ValueSemantics.entryValue],
      by simp [getVal, foundV, InPlaceSemantics.entryValue], pairedV, allocatedV, ?_,
      describes_field (i := 1) (described _ member) rfl rfl, ?_, ?_, ?_⟩
    · simp [obsTyped] at typedEntry
      exact typedEntry
    · cases tagsY with
      | record _ _ _ _ fields => exact fields 1 u value v rfl rfl rfl
    · cases chainsY _ paired with
      | record _ _ _ _ fields => exact fields 1 u value ov rfl rfl rfl
    · cases deepY with
      | record _ _ _ _ fields => exact fields 1 u value v rfl rfl rfl

/-- The lookup case: a read of the entries whose result is `ok v` with the
found value, described by the dictionary's value, or `err 0`. -/
theorem dictGet_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver key : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .dictGet [receiver, key]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredK : ∀ use ∈ atomUses key, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .dictGet [receiver, key]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .dictGet [receiver, key])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .dictGet [receiver, key])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim .dictGet [receiver, key])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim .dictGet [receiver, key])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, keyTyped, rfl⟩ :=
    exprType_dictGet_success (fun _ _ h => flat_atom_type inv h) typed
  obtain ⟨root, ys, os, roots, value, certificate, lookup, _, _, flatT, entryTags, valueShape,
    entriesShaped, entriesDescribed, lenO, entriesTyped, pointwise, _, _, valueReceiver, heapReceiver,
    abstractReceiver⟩ := flat_atom_dict_path inv receiverTyped coveredR
  obtain ⟨k, valueKey, heapKey, abstractKey⟩ := flat_atom_integer inv keyTyped coveredK
  have abstractAtoms : [receiver, key].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots value certificate, .scalar] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractKey rfl)
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_dictGet_run] at run
  have equal := Except.ok.inj run
  have resultEq : result = .record [.scalar, .scalar, value] := (congrArg Prod.fst equal).symm
  have resultRep : entryAbstract declarations (.result .int t) result =
      .record [.scalar, .scalar, entryAbstract declarations t value] := by
    rw [resultEq]; rfl
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads ((union roots value.cells).filter external)}} :=
    (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  have valueAtoms : [receiver, key].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k] := except_mapM_cons valueReceiver (except_mapM_cons valueKey rfl)
  have heapAtoms : [receiver, key].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k] := except_mapM_cons heapReceiver (except_mapM_cons heapKey rfl)
  have found := dictGet_found (gamma := gamma) (declarations := declarations) (t := t) k lenO pointwise entriesShaped
    entriesTyped entriesDescribed entryTags
  have readPaired : Corresponds hs.heap ((getObs os k).getD (.int 0)) ((getVal ys k).getD (.int 0)) := by
    rcases found with ⟨noneO, noneV⟩ | ⟨ov, v, someO, someV, pairedV, _⟩
    · rw [noneO, noneV]; exact AtomPreservation.integer_corresponds 0
    · rw [someO, someV]; exact pairedV
  have paired : Corresponds hs.heap (ValueSemantics.maybe (getObs os k)) (InPlaceSemantics.maybe (getVal ys k)) := by
    rcases found with ⟨noneO, noneV⟩ | ⟨ov, v, someO, someV, pairedV, _⟩
    · rw [noneO, noneV]
      exact Ownership.FlatFragment.Result.corresponds_err (AtomPreservation.integer_corresponds 0)
    · rw [someO, someV]
      exact Ownership.FlatFragment.Result.corresponds_ok pairedV
  have observed : obsTyped declarations (ValueSemantics.maybe (getObs os k)) (.result .int t) = true := by
    rcases found with ⟨noneO, _⟩ | ⟨ov, v, someO, _, _, _, typedV, _⟩
    · rw [noneO]; simp [ValueSemantics.maybe, obsTyped]
    · rw [someO]; simpa [ValueSemantics.maybe, obsTyped] using typedV
  have allocated : AllocatedFlatValue hs.heap (InPlaceSemantics.maybe (getVal ys k))
      (.result .int (entryType t)) := by
    rcases found with ⟨_, noneV⟩ | ⟨ov, v, _, someV, _, allocatedV, _⟩
    · rw [noneV]; exact .err .int _ (.int 0) (.int 0)
    · rw [someV]; exact .ok .int _ v allocatedV
  have described : Describes gamma hs.heap (.record [.scalar, .scalar, entryAbstract declarations t value])
      (InPlaceSemantics.maybe (getVal ys k)) := by
    rcases found with ⟨_, noneV⟩ | ⟨ov, v, _, someV, _, _, _, describedV, _⟩
    · rw [noneV]
      refine describes_record_of_fields rfl ?_
      intro i a w as_i ws_i
      rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> exact integer_described_any _ 0
    · rw [someV]
      refine describes_record_of_fields rfl ?_
      intro i a w as_i ws_i
      rcases three_pair as_i ws_i with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact integer_described_any _ 1
      · exact integer_described_any _ 0
      · exact describedV
  have tagsR : ResultTags (.result .int (entryType t)) (.record [.scalar, .scalar, entryAbstract declarations t value])
      (InPlaceSemantics.maybe (getVal ys k)) := by
    rcases found with ⟨_, noneV⟩ | ⟨ov, v, _, someV, _, _, _, _, tagsV, _⟩
    · rw [noneV]; exact .err .int _ .scalar .scalar _ (.int 0) (by simp) (.int 0)
    · rw [someV]; exact .ok .int _ .scalar .scalar _ v (resultTags_ne_bottom tagsV) tagsV
  have chainsR : ChainTags (.result .int (entryType t)) (.record [.scalar, .scalar, entryAbstract declarations t value])
      (ValueSemantics.maybe (getObs os k)) := by
    rcases found with ⟨noneO, _⟩ | ⟨ov, v, someO, _, _, _, _, _, _, chainsV, _⟩
    · rw [noneO]; exact .err .int _ .scalar .scalar _ (.int 0) (.int _ _)
    · rw [someO]; exact .ok .int _ .scalar .scalar _ ov chainsV
  have deepR : TagsDeep hs.heap (.result .int (entryType t))
      (.record [.scalar, .scalar, entryAbstract declarations t value]) (InPlaceSemantics.maybe (getVal ys k)) := by
    rcases found with ⟨_, noneV⟩ | ⟨ov, v, _, someV, _, _, _, _, _, _, deepV⟩
    · rw [noneV]; exact .err .int _ .scalar .scalar _ (.int 0) (.int _ _)
    · rw [someV]; exact .ok .int _ .scalar .scalar _ v deepV
  refine ⟨.result _ _ .int flatT, nextEscapes, by rw [resultEq]; exact .result _ _ _ _ .int valueShape, ?_, ?_⟩
  · intro value' vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · by_cases deep : ((getObs os k).getD (.int 0)).depth > observationDepth
        · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
          simp [noDepth, noFuel, valueTicked, value_dictGet_run_deep {vs with fuel := vs.fuel - 1} os k deep,
            Except.bind, bind] at run
        · have snap : snapshot hs.heap observationDepth ((getVal ys k).getD (.int 0)) =
              .ok ((getObs os k).getD (.int 0)) := readPaired observationDepth (by omega)
          obtain ⟨valueRun, heapRun⟩ := dictGet_runtime_success inv valueReceiver heapReceiver valueKey heapKey
            lookup snap deep noDepth noFuel
          rw [valueRun] at run
          cases run
          have heapSame : (heapRead hs ((getObs os k).getD (.int 0)) vs.kept.toList).heap = hs.heap := by
            unfold heapRead; rw [heapObserved_heap]
          refine ⟨InPlaceSemantics.maybe (getVal ys k), heapRead hs ((getObs os k).getD (.int 0)) vs.kept.toList,
            gamma, heapRun, ?_, Nat.le_of_eq (congrArg Array.size heapSame.symm),
            by rw [heapSame]; exact paired, by rw [heapSame, resultRep]; exact described, observed,
            by rw [heapSame]; exact valueTyped_of_corresponds paired observed, by rw [heapSame]; exact allocated,
            by rw [resultRep]; exact tagsR, by rw [resultRep]; exact chainsR,
            by rw [heapSame, resultRep]; exact deepR⟩
          rw [nextEscapes]; exact read_post_invariant inv _
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
      · by_cases deep : ((getObs os k).getD (.int 0)).depth > observationDepth
        · exact dictGet_runtime_deep inv heapReceiver heapKey lookup readPaired deep noDepth noFuel
        · have snap : snapshot hs.heap observationDepth ((getVal ys k).getD (.int 0)) =
              .ok ((getObs os k).getD (.int 0)) := readPaired observationDepth (by omega)
          have success := (dictGet_runtime_success inv valueReceiver heapReceiver valueKey heapKey
            lookup snap deep noDepth noFuel).1
          rw [success] at failed
          contradiction

/-! ### The empty dictionary: a fresh empty array of entries -/

theorem value_dictEmpty_run (s : ValueSemantics.State) (t : Ty) :
    (ValueSemantics.prim (.dictEmpty t) []).run s = .ok (.list [], s) := rfl

theorem heap_dictEmpty_run (hs : State) (t : Ty) :
    (prim (.dictEmpty t) []).run (heapTicked hs) = .ok (.ref hs.heap.size, heapAllocated hs []) := rfl

theorem dictEmpty_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {t : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.dictEmpty t) [])).run vs =
      .ok (.list [], valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.dictEmpty t) [])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapAllocated hs []) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapAllocated hs [])
    (representsMany_after_alloc (xs := heapInts []) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : ([] : List Atom).mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok [] := rfl
  have heapAtoms : ([] : List Atom).mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok [] := rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_dictEmpty_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_dictEmpty_run, heapObservedRun, Except.bind, Except.pure, bind, pure]

/-- The empty dictionary: a fresh, empty array of entries, named by the site,
described through its representation. -/
theorem dictEmpty_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {ctx : Context} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {self : Decl} {type : Ty} {t : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim (.dictEmpty t) []) = .ok type)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.dictEmpty t) []) after site).run before =
      .ok (result, next)) :
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.dictEmpty t) [])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.dictEmpty t) [])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.dictEmpty t) [])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.dictEmpty t) [])).run hs = .error actualMessage) := by
  rw [exprType_dictEmpty_success typed]
  have abstractAtoms : ([] : List Atom).mapM (m := Except String) (abstractAtom aenv) = .ok [] := rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_dictEmpty_run] at run
  obtain ⟨first, second⟩ := Prod.mk.inj (Except.ok.inj run)
  have resultEq : result = .list [.site site 0] .bottom true := first.symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by rw [← second]
  have typedResult : entryAbstract declarations (.dict t) result =
      .list [.site site 0] (.record [.scalar, .bottom]) true := by
    rw [resultEq]
    show Abstract.list [.site site 0] (.record [.scalar, entryAbstract declarations t .bottom]) true = _
    rw [entryAbstract_bottom]
  rw [typedResult, entryType_dict]
  constructor
  · intro value vs' run'
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) rfl] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) rfl] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := dictEmpty_runtime_success (t := t) inv noDepth noFuel
        rw [valueRun] at run'
        cases run'
        obtain ⟨gamma', postInvariant, fresh, _⟩ := literal_post_invariant inv [] site
        have heapEq : (heapObserved (heapAllocated hs []) vs.kept.toList).heap = hs.heap.push [] := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.push [])[hs.heap.size]? = some (([] : List Int).map Value.int) := by simp
        have lookupEmpty : (hs.heap.push [])[hs.heap.size]? = some [] := by simp
        have rootNamed : named gamma' [.site site 0] hs.heap.size := ⟨.site site 0, by simp, fresh⟩
        have pairedNew : Corresponds (hs.heap.push []) (.list []) (.ref hs.heap.size) :=
          corresponds_integer_ref (integers := []) lookupNew
        have shapedNew : AllocatedFlatValue (hs.heap.push []) (.ref hs.heap.size)
            (.list (.record [.int, entryType t])) :=
          .list _ [] _ lookupEmpty (by intro w member; simp at member)
        have observedNew : obsTyped declarations (.list []) (.dict t) = true := by simp [obsTyped]
        refine ⟨.ref hs.heap.size, heapObserved (heapAllocated hs []) vs.kept.toList, gamma', heapRun,
          by rw [nextEscapes]; exact postInvariant, by rw [heapEq]; simp, by rw [heapEq]; exact pairedNew,
          by rw [heapEq]; exact allocated_list_described lookupNew rootNamed, observedNew,
          by rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew,
          by rw [heapEq]; exact shapedNew, .list _ _ _ _ _, .list _ _ _,
          by rw [heapEq]; exact tagsDeep_list lookupEmpty (by intro w member; simp at member)⟩
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) rfl]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) rfl]
          simp [noDepth, heapFuel]⟩
      · have success := (dictEmpty_runtime_success (t := t) inv noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### The remove: the entries with another key -/

/-- The entries both interpreters keep correspond, in order. -/
theorem dictDrop_corresponds {heap : Heap} (k : Int) :
    ∀ (os : List Observation) (ys : List Value), os.length = ys.length →
      (∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds heap o y) →
      (∀ y ∈ ys, ∃ k' v, y = .record [.int k', v]) →
      (dictDrop ValueSemantics.entryKey os k).length = (dictDrop InPlaceSemantics.entryKey ys k).length ∧
      ∀ (i : Nat) (o : Observation) (y : Value), (dictDrop ValueSemantics.entryKey os k)[i]? = some o →
        (dictDrop InPlaceSemantics.entryKey ys k)[i]? = some y → Corresponds heap o y
  | [], [], _, _, _ => ⟨rfl, fun i o y h _ => by simp [dictDrop] at h⟩
  | o :: os, y :: ys, len, pointwise, entries => by
    obtain ⟨k', v, rfl⟩ := entries y (by simp)
    obtain ⟨ov, rfl, _⟩ := entry_corresponds (pointwise 0 o _ rfl rfl)
    obtain ⟨lenRest, pointRest⟩ := dictDrop_corresponds k os ys (by simpa using len)
      (fun i o' y' os_i ys_i => pointwise (i + 1) o' y' os_i ys_i)
      (fun y' member => entries y' (by simp [member]))
    by_cases same : k' = k
    · subst same
      have dropO : dictDrop ValueSemantics.entryKey (.record [.int k', ov] :: os) k' =
          dictDrop ValueSemantics.entryKey os k' := by
        simp [dictDrop, ValueSemantics.entryKey]
      have dropV : dictDrop InPlaceSemantics.entryKey (.record [.int k', v] :: ys) k' =
          dictDrop InPlaceSemantics.entryKey ys k' := by
        simp [dictDrop, InPlaceSemantics.entryKey]
      rw [dropO, dropV]
      exact ⟨lenRest, pointRest⟩
    · have keepO : dictDrop ValueSemantics.entryKey (.record [.int k', ov] :: os) k =
          .record [.int k', ov] :: dictDrop ValueSemantics.entryKey os k := by
        simp [dictDrop, ValueSemantics.entryKey, same]
      have keepV : dictDrop InPlaceSemantics.entryKey (.record [.int k', v] :: ys) k =
          .record [.int k', v] :: dictDrop InPlaceSemantics.entryKey ys k := by
        simp [dictDrop, InPlaceSemantics.entryKey, same]
      rw [keepO, keepV]
      refine ⟨by simp [lenRest], ?_⟩
      intro i o' y' os_i ys_i
      cases i with
      | zero =>
        simp at os_i ys_i
        subst os_i; subst ys_i
        exact pointwise 0 _ _ rfl rfl
      | succ i => exact pointRest i o' y' os_i ys_i
  | [], _ :: _, len, _, _ => by simp at len
  | _ :: _, [], len, _, _ => by simp at len

/-- The kept elements' representation and the dropped elements' one make a
representation of all elements whose footprint holds the kept footprint as a
sublist. -/
theorem representsMany_filter_merge {heap : Heap} (p : Value → Bool) :
    ∀ (ys : List Value) {n m : Nat} {os os0 : List Observation} {cs cs0 : List Nat},
      RepresentsMany heap n (ys.filter p) os cs → RepresentsMany heap m ys os0 cs0 →
      ∃ os' cs', RepresentsMany heap (max n m) ys os' cs' ∧ cs.Sublist cs'
  | [], _, _, _, _, _, _, kept, _ => by
    simp only [List.filter_nil] at kept
    cases kept
    exact ⟨[], [], .nil, List.Sublist.refl _⟩
  | y :: ys, n, m, os, os0, cs, cs0, kept, all => by
    cases all with
    | @cons _ _ oy0 fy0 _ _ cs0' firstAll restAll =>
      by_cases keep : p y = true
      · rw [List.filter_cons_of_pos keep] at kept
        cases kept with
        | @cons _ _ oy fy _ _ csRest first rest =>
          obtain ⟨os', cs', merged, sub⟩ := representsMany_filter_merge p ys rest restAll
          refine ⟨oy :: os', fy ++ cs', .cons (Ownership.FlatFragment.RepresentsDepth.represents_of_depth first ?_) merged,
            List.Sublist.append (List.Sublist.refl fy) sub⟩
          exact Nat.le_trans (represents_depth_bound first) (Nat.le_max_left n m)
      · rw [List.filter_cons_of_neg keep] at kept
        obtain ⟨os', cs', merged, sub⟩ := representsMany_filter_merge p ys kept restAll
        refine ⟨oy0 :: os', fy0 ++ cs', .cons (Ownership.FlatFragment.RepresentsDepth.represents_of_depth firstAll ?_) merged,
          List.Sublist.trans sub (List.sublist_append_right fy0 cs')⟩
        exact Nat.le_trans (represents_depth_bound firstAll) (Nat.le_max_right n m)

/-- After a remove, the entries' footprint repeats no array: it is a sublist
of the old one. -/
theorem filtered_footprint_nodup {heap next : Heap} {root : Nat} {ys : List Value} (p : Value → Bool)
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some ys) (lookupNew : next[root]? = some (ys.filter p))
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (oldNodup : ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup) :
    ∀ n o fp, Represents next n (.ref root) o fp → fp.Nodup := by
  intro n o fp rep
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    have childrenHeap := representsMany_elements_apart children
      (fun y member => agreeOld y ((List.mem_filter.mp member).1))
    cases represented with
    | @ref _ _ n1 _ _ lookup0 children0 =>
      rw [lookup] at lookup0
      cases lookup0
      obtain ⟨os', cs', merged, sub⟩ := representsMany_filter_merge p ys childrenHeap children0
      have oldOk := oldNodup _ _ _ (.ref lookup merged)
      rw [List.nodup_cons] at oldOk ⊢
      exact ⟨fun member => oldOk.1 (sub.subset member), sub.nodup oldOk.2⟩

/-- After a remove, an array at a container position of a kept entry appears
once in the footprint: at most as often as in the old one, and at least once. -/
theorem filtered_footprint_once {heap next : Heap} {root : Nat} {ys : List Value} (p : Value → Bool)
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (lookup : heap[root]? = some ys) (lookupNew : next[root]? = some (ys.filter p))
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (oldOnce : ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ q c, containerPath q = true → ArrayAt heap (.ref root) (.element :: q) c → fp.count c = 1) :
    ∀ n o fp, Represents next n (.ref root) o fp →
      ∀ q c, containerPath q = true → ArrayAt next (.ref root) (.element :: q) c → fp.count c = 1 := by
  intro n o fp rep q c container located
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    have childrenHeap := representsMany_elements_apart children
      (fun y member => agreeOld y ((List.mem_filter.mp member).1))
    cases represented with
    | @ref _ _ n1 _ _ lookup0 children0 =>
      rw [lookup] at lookup0
      cases lookup0
      obtain ⟨os', cs', merged, sub⟩ := representsMany_filter_merge p ys childrenHeap children0
      cases located with
      | @element _ _ z _ _ lookup'' member inner =>
        rw [lookupNew] at lookup''
        cases lookup''
        have zOld : z ∈ ys := (List.mem_filter.mp member).1
        have innerHeap : AtPath heap z q (.ref c) := atPath_of_agree_rev (agreeOld z zOld) inner
        have oldCount := oldOnce _ _ _ (.ref lookup merged) q c container (.element lookup zOld innerHeap)
        have inKept : c ∈ _ :=
          Ownership.FlatFragment.FiniteReach.representsMany_reach_member childrenHeap member
            (reaches_of_atPath innerHeap)
        have le := (List.Sublist.cons₂ root sub).count_le c
        have pos : 0 < (root :: _).count c := List.count_pos_iff.mpr (List.mem_cons_of_mem _ inKept)
        omega

theorem value_dictRemove_run (s : ValueSemantics.State) (os : List Observation) (k : Int) :
    (ValueSemantics.prim .dictRemove [.list os, .int k]).run s =
      .ok (.list (dictDrop ValueSemantics.entryKey os k), s) := rfl

theorem heap_dictRemove_run (s : State) (ys : List Value) (k : Int)
    (lookup : s.heap[root]? = some ys) (links : s.links = []) :
    (prim .dictRemove [.ref root, .int k]).run s =
      .ok (.ref root, {s with heap := s.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k), writes := (if ys == dictDrop InPlaceSemantics.entryKey ys k then s.writes else s.writes + 1)}) := by
  have written := writeCounted_empty_run (root := root) (stored := dictDrop InPlaceSemantics.entryKey ys k)
    s lookup links
  simpa [prim, array, lookup, StateT.run, StateT.bind, StateT.get, Option.toExcept, Except.bind,
    Except.pure, bind, pure, get, getThe, MonadStateOf.get, StateT.pure, StateT.lift, liftM, monadLift,
    MonadLift.monadLift] using written

def heapStored (hs : State) (root : Nat) (ys stored : List Value) : State :=
  { hs with
    fuel := hs.fuel - 1
    heap := hs.heap.set! root stored
    writes := (if ys == stored then hs.writes else hs.writes + 1) }

theorem dictRemove_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver key : Atom} {os : List Observation} {ys : List Value} {k : Int} {root : Nat} {footprint : List Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueKey : ValueSemantics.atom (valueEnv env) key = .ok (.int k))
    (heapKey : InPlaceSemantics.atom (heapEnv env) key = .ok (.int k))
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .dictRemove [receiver, key])).run vs =
      .ok (.list (dictDrop ValueSemantics.entryKey os k), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .dictRemove [receiver, key])).run hs =
      .ok (.ref root, heapObserved (heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k))
        vs.kept.toList) := by
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have framed : RepresentsMany (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k)) observationDepth
      hs.kept.toList vs.kept.toList footprint :=
    representsMany_after_write (xs := dictDrop InPlaceSemantics.entryKey ys k) represented rootOutside
  have heapObservedRun := heap_observeKept_run (heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k)) framed
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, key].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k] := except_mapM_cons valueReceiver (except_mapM_cons valueKey rfl)
  have heapAtoms : [receiver, key].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k] := except_mapM_cons heapReceiver (except_mapM_cons heapKey rfl)
  have removeRun : (prim .dictRemove [.ref root, .int k]).run (heapTicked hs) =
      .ok (.ref root, heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k)) :=
    heap_dictRemove_run (heapTicked hs) ys k lookup inv.links
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_dictRemove_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, removeRun, heapObservedRun, Except.bind, Except.pure, bind, pure]

/-- A list of entry records is typed as a dictionary. -/
theorem obsTyped_dict_of_elements {ds : List Decl} {os : List Observation} {t : Ty}
    (elements : ∀ o ∈ os, obsTyped ds o (.record [.int, t]) = true) : obsTyped ds (.list os) (.dict t) = true := by
  unfold obsTyped
  change os.attach.all (fun item => obsTyped ds item.val (.record [.int, t])) = true
  exact List.all_eq_true.mpr (fun item _ => elements item.val item.property)

/-- The remove: the checker demands the entries and keeps the dictionary's
description; both interpreters keep the entries with another key, the heap in
place. The kept entries are old entries, so their descriptions, tags and
certificates carry over. -/
theorem dictRemove_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver key : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .dictRemove [receiver, key]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredK : ∀ use ∈ atomUses key, use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .dictRemove [receiver, key]) after site).run before =
      .ok (result, next)) :
    Preserved declarations depth env vs hs (.prim .dictRemove [receiver, key]) after aenv tenv
      next.facts.escapes result type := by
  obtain ⟨t, receiverTyped, keyTyped, rfl⟩ :=
    exprType_dictRemove_success (fun _ _ h => flat_atom_type inv h) typed
  obtain ⟨root, ys, os, roots, value, certificate, lookup, receiverNamed, noUnk, _, entryTags,
    valueShape, entriesShaped, entriesDescribed, lenO, entriesTyped, pointwise, pairedList, described,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_dict_path inv receiverTyped coveredR
  obtain ⟨k, valueKey, heapKey, abstractKey⟩ := flat_atom_integer inv keyTyped coveredK
  have abstractAtoms : [receiver, key].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots value certificate, .scalar] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractKey rfl)
  obtain ⟨childFuel, _, scope, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  obtain ⟨demanded, resultEq⟩ := primitive_dictRemove_run run
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig, liveCellsWith_default] at demanded
  have escapesEq := demand_success_escapes demanded
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : root ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded receiverNamed represented
  have separate := demand_success_live_separate inv.separating demanded
  have apart := live_path_apart inv scope afterSub receiverNamed separate
  subst resultEq
  have valueAtoms : [receiver, key].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k] := except_mapM_cons valueReceiver (except_mapM_cons valueKey rfl)
  have heapAtoms : [receiver, key].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k] := except_mapM_cons heapReceiver (except_mapM_cons heapKey rfl)
  constructor
  · intro result' vs' run'
    rw [entryAbstract_dict_list, entryType_dict]
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := dictRemove_runtime_success inv valueReceiver heapReceiver valueKey
          heapKey lookup rootOutside represented noDepth noFuel
        rw [valueRun] at run'
        cases run'
        have valid : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
        have heapEq : (heapObserved (heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k))
            vs.kept.toList).heap = hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k) := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))[root]? =
            some (dictDrop InPlaceSemantics.entryKey ys k) := by simp [valid]
        have sizeEq : (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k)).size = hs.heap.size := by simp
        have keptOld : ∀ z ∈ dictDrop InPlaceSemantics.entryKey ys k, z ∈ ys :=
          fun z member => (List.mem_filter.mp member).1
        obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
        have agreeOld : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))[c]? = hs.heap[c]? :=
          fun y member => element_agree_after_write represented0 lookup member
        have shapedZ : ∀ z ∈ dictDrop InPlaceSemantics.entryKey ys k,
            AllocatedFlatValue (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k)) z
              (.record [.int, entryType t]) :=
          fun z member => allocated_of_agree (entriesShaped z (keptOld z member)) (agreeOld z (keptOld z member))
        have shapedNew : AllocatedFlatValue (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))
            (.ref root) (.list (.record [.int, entryType t])) := .list root _ _ lookupNew shapedZ
        have describedZ : ∀ z ∈ dictDrop InPlaceSemantics.entryKey ys k,
            Describes gamma (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))
              (.record [.scalar, entryAbstract declarations t value]) z :=
          fun z member => describes_of_agree (agreeOld z (keptOld z member)) (entriesDescribed z (keptOld z member))
        have oldCert := described.1.2 [] roots (.record [.scalar, entryAbstract declarations t value]) certificate (.ref root) rfl (.here _)
        have describedNew : Describes gamma (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))
            (.list roots (.record [.scalar, entryAbstract declarations t value]) certificate) (.ref root) :=
          list_described_of_elements receiverNamed noUnk lookupNew shapedNew describedZ
            (fun d => filtered_footprint_nodup (fun e => InPlaceSemantics.entryKey e != some k) lookup lookupNew
              represented0 agreeOld (fun n o fp rep => (oldCert n o fp rep).1 d))
            (fun sp => filtered_footprint_once (fun e => InPlaceSemantics.entryKey e != some k) lookup lookupNew
              represented0 agreeOld (fun n o fp rep => (oldCert n o fp rep).2 sp))
        have dropped := dictDrop_corresponds k os ys lenO pointwise (fun y member => by
          obtain ⟨k', v, eq, _⟩ := entry_shape (entriesShaped y member)
          exact ⟨k', v, eq⟩)
        have pairedNew : Corresponds (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))
            (.list (dictDrop ValueSemantics.entryKey os k)) (.ref root) :=
          corresponds_list_of_elements lookupNew dropped.1 (fun i o y os_i ys_i =>
            corresponds_of_agree (agreeOld y (keptOld y (List.mem_of_getElem? ys_i))) (dropped.2 i o y os_i ys_i))
        have observedNew : obsTyped declarations (.list (dictDrop ValueSemantics.entryKey os k)) (.dict t) = true :=
          obsTyped_dict_of_elements (fun o member => entriesTyped o (List.mem_filter.mp member).1)
        have deepNew : TagsDeep (hs.heap.set! root (dictDrop InPlaceSemantics.entryKey ys k))
            (.list (.record [.int, entryType t])) (.list roots (.record [.scalar, entryAbstract declarations t value]) certificate) (.ref root) :=
          tagsDeep_list lookupNew (fun z member =>
            elementTags_of_agree (entryTags z (keptOld z member)) (agreeOld z (keptOld z member)))
        refine ⟨.ref root, heapObserved (heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k))
            vs.kept.toList, gamma, heapRun, ?_, Nat.le_of_eq (by rw [heapEq, sizeEq]),
          by rw [heapEq]; exact pairedNew, by rw [heapEq]; exact describedNew, observedNew,
          by rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew,
          by rw [heapEq]; exact shapedNew, .list _ _ _ _ _, .list _ _ _, by rw [heapEq]; exact deepNew⟩
        rw [escapesEq]
        refine flatInvariant_heap_frame inv (hole := root) (footprint := footprint) afterSub
          (by rw [heapEq, sizeEq]; exact Nat.le_refl _)
          ⟨dictDrop InPlaceSemantics.entryKey ys k, by rw [heapEq]; exact lookupNew, ?_⟩
          (by rw [heapObserved_links]; exact inv.links) ?_ apart represented rootOutside
          (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) (fun _ _ _ => Iff.rfl)
          (by rw [heapEq, sizeEq]; exact inv.namingBound) inv.separating
          (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
          (observed_external (valueTicked vs) (heapStored hs root ys (dictDrop InPlaceSemantics.entryKey ys k))
            inv.keptSize inv.external)
          (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapStored, inv.fuel])
          (fun _ escaped => escaped)
        · intro z member d reach
          rw [heapEq] at reach ⊢
          exact allocated_reach_bound (shapedZ z member) reach
        · intro c different
          rw [heapEq]
          exact lookup_set_other hs.heap root _ different
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
      · have success := (dictRemove_runtime_success inv valueReceiver heapReceiver valueKey heapKey lookup
          rootOutside represented noDepth noFuel).1
        rw [success] at failed
        contradiction

/-! ### Entry records: what an entry reaches is what its value reaches -/

theorem reaches_entry {heap : Heap} {k : Int} {v : Value} {c : Nat}
    (reach : Reaches heap (.record [.int k, v]) (.ref c)) : Reaches heap v (.ref c) := by
  cases reach with
  | field member inner =>
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl
    · cases inner
    · exact inner

theorem arrayAt_entry {heap : Heap} {k : Int} {v : Value} {p : Path} {c : Nat}
    (located : ArrayAt heap (.record [.int k, v]) p c) : ∃ p', p = .field 1 :: p' ∧ ArrayAt heap v p' c := by
  unfold ArrayAt at located
  cases located with
  | @field _ i x q _ lookup inner =>
    match i, lookup with
    | 0, lookup =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at lookup
      subst lookup
      cases inner
    | 1, lookup =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at lookup
      subst lookup
      exact ⟨q, rfl, inner⟩
    | _ + 2, lookup => simp at lookup

theorem represents_entry {heap : Heap} {n : Nat} {k : Int} {v : Value} {o : Observation} {fp : List Nat}
    (rep : Represents heap n (.record [.int k, v]) o fp) :
    ∃ n' o' fp', Represents heap n' v o' fp' ∧ fp = fp' := by
  cases rep with
  | record children =>
    cases children with
    | cons first rest =>
      cases first
      cases rest with
      | cons second last =>
        cases last
        exact ⟨_, _, _, second, by simp⟩

theorem covers_entry_value {gamma : Naming} {heap : Heap} {a : Abstract} {k : Int} {v : Value}
    (covers : Covers gamma heap (.record [.scalar, a]) (.record [.int k, v])) : Covers gamma heap a v :=
  fun q c located => covers (.field 1 :: q) c (AtPath.field (i := 1) rfl located)

theorem containerPath_entry {p : Path} (container : containerPath (.field 1 :: p) = true) :
    containerPath p = true := by
  simpa [containerPath] using container

theorem entry_join (a b : Abstract) :
    (Abstract.record [.scalar, a]).join (.record [.scalar, b]) = .record [.scalar, a.join b] := by
  rw [join_two, join_scalar]

/-- A new entry: the record of the key and the stored value. -/
theorem entry_allocated {heap : Heap} {k : Int} {w : Value} {t : Ty} (allocated : AllocatedFlatValue heap w t) :
    AllocatedFlatValue heap (.record [.int k, w]) (.record [.int, t]) := by
  refine .record _ _ rfl ?_
  intro i w' t' hw ht
  match i, hw, ht with
  | 0, hw, ht =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at hw ht
    subst hw; subst ht
    exact .int k
  | 1, hw, ht =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at hw ht
    subst hw; subst ht
    exact allocated
  | _ + 2, hw, _ => simp at hw

theorem entry_corresponds_intro {heap : Heap} {k : Int} {o : Observation} {w : Value}
    (paired : Corresponds heap o w) : Corresponds heap (.record [.int k, o]) (.record [.int k, w]) := by
  refine corresponds_record_of_fields rfl ?_
  intro i o' w' ho hw
  match i, ho, hw with
  | 0, ho, hw =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at ho hw
    subst ho; subst hw
    exact AtomPreservation.integer_corresponds k
  | 1, ho, hw =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ho hw
    subst ho; subst hw
    exact paired
  | _ + 2, ho, _ => simp at ho

theorem entry_described {gamma : Naming} {heap : Heap} {a : Abstract} {k : Int} {w : Value}
    (described : Describes gamma heap a w) :
    Describes gamma heap (.record [.scalar, a]) (.record [.int k, w]) := by
  refine describes_record_of_fields rfl ?_
  intro i a' w' ha hw
  match i, ha, hw with
  | 0, ha, hw =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at ha hw
    subst ha; subst hw
    exact integer_described_any _ k
  | 1, ha, hw =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ha hw
    subst ha; subst hw
    exact described
  | _ + 2, ha, _ => simp at ha

theorem entry_observed {ds : List Decl} {k : Int} {o : Observation} {t : Ty}
    (observed : obsTyped ds o t = true) : obsTyped ds (.record [.int k, o]) (.record [.int, t]) = true := by
  refine obsTyped_record_of_fields rfl ?_
  intro i o' t' ho ht
  match i, ho, ht with
  | 0, ho, ht =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at ho ht
    subst ho; subst ht
    simp [obsTyped]
  | 1, ho, ht =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ho ht
    subst ho; subst ht
    exact observed
  | _ + 2, ho, _ => simp at ho

theorem entry_elementTags {heap : Heap} {t : Ty} {a : Abstract} {k : Int} {w : Value} {o : Observation}
    (paired : Corresponds heap o w) (tags : ResultTags t a w) (chains : ChainTags t a o)
    (deep : TagsDeep heap t a w) :
    ElementTags heap (.record [.int, t]) (.record [.scalar, a]) (.record [.int k, w]) := by
  refine elementTags_of_corresponds (o := .record [.int k, o]) (entry_corresponds_intro paired) ?_ ?_ ?_
  · refine .record _ _ _ rfl ?_
    intro i t' a' w' ht ha hw
    match i, ht, ha, hw with
    | 0, ht, ha, hw =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at ht ha hw
      subst ht; subst ha; subst hw
      exact .int k
    | 1, ht, ha, hw =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ht ha hw
      subst ht; subst ha; subst hw
      exact tags
    | _ + 2, ht, _, _ => simp at ht
  · refine .record _ _ _ rfl ?_
    intro i t' a' o' ht ha ho
    match i, ht, ha, ho with
    | 0, ht, ha, ho =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at ht ha ho
      subst ht; subst ha; subst ho
      exact .int _ _
    | 1, ht, ha, ho =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ht ha ho
      subst ht; subst ha; subst ho
      exact chains
    | _ + 2, ht, _, _ => simp at ht
  · refine .record _ _ _ rfl ?_
    intro i t' a' w' ht ha hw
    match i, ht, ha, hw with
    | 0, ht, ha, hw =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at ht ha hw
      subst ht; subst ha; subst hw
      exact .int _ _
    | 1, ht, ha, hw =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ht ha hw
      subst ht; subst ha; subst hw
      exact deep
    | _ + 2, ht, _, _ => simp at ht

/-! ### The insert: a push of the entry, or an in-place set of its old entry -/

/-- The stored entries are the old ones with the entry of the key replaced, or
the new entry appended: either way `as ++ e :: bs` from `as ++ mid ++ bs`. -/
theorem dictPut_split {α : Type} (key : α → Option Int) (es : List α) (k : Int) (e : α) :
    ∃ as mid bs, es = as ++ mid ++ bs ∧ dictPut key es k e = as ++ e :: bs := by
  unfold dictPut
  cases found : es.findIdx? (fun e => key e == some k) with
  | none => exact ⟨es, [], [], by simp, by simp⟩
  | some i =>
    obtain ⟨lt, _⟩ := List.findIdx?_eq_some_iff_getElem.mp found
    refine ⟨es.take i, [es[i]], es.drop (i + 1), ?_, ?_⟩
    · rw [List.append_assoc, List.singleton_append, ← List.drop_eq_getElem_cons lt, List.take_append_drop]
    · simp only
      rw [List.set_eq_take_append_cons_drop, if_pos lt]

theorem mem_dictPut {α : Type} {key : α → Option Int} {es : List α} {k : Int} {e z : α}
    (member : z ∈ dictPut key es k e) : z ∈ es ∨ z = e := by
  obtain ⟨as, mid, bs, esEq, putEq⟩ := dictPut_split key es k e
  rw [putEq] at member
  rw [esEq]
  simp only [List.mem_append, List.mem_cons] at member ⊢
  rcases member with inA | rfl | inB
  · exact Or.inl (Or.inl (Or.inl inA))
  · exact Or.inr rfl
  · exact Or.inl (Or.inr inB)

/-- Both interpreters find the entry of a key at the same index. -/
theorem findIdx_entries_corresponds {heap : Heap} (k : Int) :
    ∀ (os : List Observation) (ys : List Value), os.length = ys.length →
      (∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y → Corresponds heap o y) →
      (∀ y ∈ ys, ∃ k' v, y = .record [.int k', v]) →
      os.findIdx? (fun e => ValueSemantics.entryKey e == some k) =
        ys.findIdx? (fun e => InPlaceSemantics.entryKey e == some k)
  | [], [], _, _, _ => rfl
  | o :: os, y :: ys, len, pointwise, entries => by
    obtain ⟨k', v, rfl⟩ := entries y (by simp)
    obtain ⟨ov, rfl, _⟩ := entry_corresponds (pointwise 0 o _ rfl rfl)
    have rest := findIdx_entries_corresponds k os ys (by simpa using len)
      (fun i o' y' os_i ys_i => pointwise (i + 1) o' y' os_i ys_i)
      (fun y' member => entries y' (by simp [member]))
    have keyO : ValueSemantics.entryKey (.record [.int k', ov]) = some k' := rfl
    have keyV : InPlaceSemantics.entryKey (.record [.int k', v]) = some k' := rfl
    simp only [List.findIdx?_cons, keyO, keyV, rest]
  | [], _ :: _, len, _, _ => by simp at len
  | _ :: _, [], len, _, _ => by simp at len

/-- The stored entries correspond, in order. -/
theorem dictPut_corresponds {heap : Heap} (k : Int) {os : List Observation} {ys : List Value}
    {oe : Observation} {e : Value}
    (len : os.length = ys.length)
    (pointwise : ∀ (i : Nat) (o : Observation) (y : Value), os[i]? = some o → ys[i]? = some y →
      Corresponds heap o y)
    (entries : ∀ y ∈ ys, ∃ k' v, y = .record [.int k', v])
    (pairedE : Corresponds heap oe e) :
    (dictPut ValueSemantics.entryKey os k oe).length = (dictPut InPlaceSemantics.entryKey ys k e).length ∧
    ∀ (i : Nat) (o : Observation) (y : Value), (dictPut ValueSemantics.entryKey os k oe)[i]? = some o →
      (dictPut InPlaceSemantics.entryKey ys k e)[i]? = some y → Corresponds heap o y := by
  have same := findIdx_entries_corresponds k os ys len pointwise entries
  unfold dictPut
  rw [same]
  cases ys.findIdx? (fun e => InPlaceSemantics.entryKey e == some k) with
  | none =>
    refine ⟨by simp [len], ?_⟩
    intro i o y oi yi
    by_cases lt : i < os.length
    · rw [List.getElem?_append_left lt] at oi
      rw [List.getElem?_append_left (len ▸ lt)] at yi
      exact pointwise i o y oi yi
    · rw [List.getElem?_append_right (by omega)] at oi
      rw [List.getElem?_append_right (by omega)] at yi
      have zero : i - os.length = 0 := by
        cases h : i - os.length with
        | zero => rfl
        | succ n => rw [h] at oi; simp at oi
      rw [zero] at oi
      rw [← len, zero] at yi
      simp only [List.getElem?_cons_zero, Option.some.injEq] at oi yi
      subst oi; subst yi
      exact pairedE
  | some j =>
    refine ⟨by simp [len], ?_⟩
    intro i o y oi yi
    rw [List.getElem?_set] at oi yi
    by_cases same : j = i
    · subst same
      rw [if_pos rfl] at oi yi
      by_cases lt : j < os.length
      · rw [if_pos lt] at oi
        rw [if_pos (len ▸ lt)] at yi
        simp only [Option.some.injEq] at oi yi
        subst oi; subst yi
        exact pairedE
      · rw [if_neg lt] at oi
        contradiction
    · rw [if_neg same] at oi yi
      exact pointwise i o y oi yi

theorem value_dictInsert_run (s : ValueSemantics.State) (os : List Observation) (k : Int) (o : Observation) :
    (ValueSemantics.prim .dictInsert [.list os, .int k, o]).run s =
      .ok (.list (dictPut ValueSemantics.entryKey os k (.record [.int k, o])), s) := rfl

theorem heap_dictInsert_run (s : State) (ys : List Value) (k : Int) (w : Value)
    (lookup : s.heap[root]? = some ys) (links : s.links = []) :
    (prim .dictInsert [.ref root, .int k, w]).run s =
      .ok (.ref root, {s with heap := s.heap.set! root (dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w])), writes := (if ys == dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]) then s.writes else s.writes + 1)}) := by
  have written := writeCounted_empty_run (root := root)
    (stored := dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w])) s lookup links
  simpa [prim, array, lookup, StateT.run, StateT.bind, StateT.get, Option.toExcept, Except.bind,
    Except.pure, bind, pure, get, getThe, MonadStateOf.get, StateT.pure, StateT.lift, liftM, monadLift,
    MonadLift.monadLift] using written

theorem dictInsert_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver key item : Atom} {os : List Observation} {ys : List Value} {o : Observation} {w : Value} {k : Int} {root : Nat} {footprint : List Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (valueKey : ValueSemantics.atom (valueEnv env) key = .ok (.int k))
    (heapKey : InPlaceSemantics.atom (heapEnv env) key = .ok (.int k))
    (valueItem : ValueSemantics.atom (valueEnv env) item = .ok o)
    (heapItem : InPlaceSemantics.atom (heapEnv env) item = .ok w)
    (lookup : hs.heap[root]? = some ys)
    (rootOutside : root ∉ footprint)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim .dictInsert [receiver, key, item])).run vs =
      .ok (.list (dictPut ValueSemantics.entryKey os k (.record [.int k, o])), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim .dictInsert [receiver, key, item])).run hs =
      .ok (.ref root, heapObserved (heapStored hs root ys
        (dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]))) vs.kept.toList) := by
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have framed : RepresentsMany (hs.heap.set! root (dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w])))
      observationDepth hs.kept.toList vs.kept.toList footprint :=
    representsMany_after_write (xs := dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]))
      represented rootOutside
  have heapObservedRun := heap_observeKept_run
    (heapStored hs root ys (dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]))) framed
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver, key, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k, o] :=
    except_mapM_cons valueReceiver (except_mapM_cons valueKey (except_mapM_cons valueItem rfl))
  have heapAtoms : [receiver, key, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapKey (except_mapM_cons heapItem rfl))
  have insertRun : (prim .dictInsert [.ref root, .int k, w]).run (heapTicked hs) =
      .ok (.ref root, heapStored hs root ys (dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]))) :=
    heap_dictInsert_run (heapTicked hs) ys k w lookup inv.links
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_dictInsert_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, insertRun, heapObservedRun, Except.bind, Except.pure, bind, pure]

/-- The insert: the checker demands the entries and the value, and joins the
value's description into the entries'; both interpreters replace the entry of
the key or append a new one, the heap in place. The new entry's certificates
come from the store tests on the value, read through the entry's field 1. -/
theorem dictInsert_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver key item : Atom} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim .dictInsert [receiver, key, item]) = .ok type)
    (coveredR : ∀ use ∈ atomUses receiver, use ∈ live)
    (coveredK : ∀ use ∈ atomUses key, use ∈ live)
    (coveredV : ∀ use ∈ atomUses item, use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim .dictInsert [receiver, key, item]) after site).run before =
      .ok (result, next)) :
    Preserved declarations depth env vs hs (.prim .dictInsert [receiver, key, item]) after aenv tenv
      next.facts.escapes result type := by
  obtain ⟨t, receiverTyped, keyTyped, itemTyped, rfl⟩ :=
    exprType_dictInsert_success (fun _ _ h => flat_atom_type inv h) typed
  obtain ⟨root, ys, os, roots, value0, certificate, lookup, receiverNamed, noUnk, _, entryTags,
    valueShape0, entriesShaped, entriesDescribed, lenO, entriesTyped, pointwise, pairedList, described,
    valueReceiver, heapReceiver, abstractReceiver⟩ := flat_atom_dict_path inv receiverTyped coveredR
  obtain ⟨k, valueKey, heapKey, abstractKey⟩ := flat_atom_integer inv keyTyped coveredK
  obtain ⟨o, w, aN0, valueItem, heapItem, abstractItem, pairedN, describedN, observedN, _, _, shapeN0,
    allocatedN, tagsN, chainsN, deepN⟩ := flat_atom_entry inv itemTyped coveredV
  have abstractAtoms : [receiver, key, item].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots value0 certificate, .scalar, aN0] :=
    except_mapM_cons abstractReceiver (except_mapM_cons abstractKey (except_mapM_cons abstractItem rfl))
  obtain ⟨childFuel, _, scope, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  have demanded := primitive_dictInsert_demand_run run
  rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
    defaultConfig, liveCellsWith_default] at demanded
  rw [← cells_entryAbstract (ds := declarations) valueShape0, ← cells_entryAbstract (ds := declarations) shapeN0]
    at demanded
  have escapesEq := demand_success_escapes demanded
  have resultEq := primitive_dictInsert_result
    (show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig) run
  have resultRep := entryAbstract_stored_dict (ds := declarations) valueShape0 shapeN0 resultEq
  -- From here the value and the item are read at their representation (#1840):
  -- the names `value` and `aN` denote `entryAbstract declarations t value0` and
  -- `entryAbstract declarations t aN0`, and `value0` and `aN0` are the checker's abstracts.
  have valueShape := flatAbstract_entry (ds := declarations) valueShape0
  have shapeN := flatAbstract_entry (ds := declarations) shapeN0
  obtain ⟨value, valueDef⟩ : ∃ x, x = entryAbstract declarations t value0 := ⟨_, rfl⟩
  obtain ⟨aN, aNDef⟩ : ∃ x, x = entryAbstract declarations t aN0 := ⟨_, rfl⟩
  simp only [← valueDef, ← aNDef] at entryTags entriesDescribed described describedN tagsN chainsN deepN valueShape shapeN demanded resultRep
  obtain ⟨footprint, represented⟩ := inv.observers
  have rootOutside : root ∉ footprint :=
    demand_success_observer_footprint inv.toInvariant demanded receiverNamed represented
  have separate := demand_success_live_separate inv.separating demanded
  have apart := live_path_apart inv scope afterSub receiverNamed separate
  have itemApartRoot : ¬ Reaches hs.heap w (.ref root) :=
    value_apart_root shapeN describedN.1.1 receiverNamed (demand_success_disjoint inv.separating demanded)
      (fun o' member => mem_union _ _ _ (Or.inr member))
  have valueAtoms : [receiver, key, item].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os, .int k, o] :=
    except_mapM_cons valueReceiver (except_mapM_cons valueKey (except_mapM_cons valueItem rfl))
  have heapAtoms : [receiver, key, item].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root, .int k, w] :=
    except_mapM_cons heapReceiver (except_mapM_cons heapKey (except_mapM_cons heapItem rfl))
  constructor
  · intro result' vs' run'
    rw [resultRep, entryType_dict]
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
      simp [noDepth] at run'
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run'
        simp [noDepth, noFuel] at run'
      · obtain ⟨valueRun, heapRun⟩ := dictInsert_runtime_success inv valueReceiver heapReceiver valueKey
          heapKey valueItem heapItem lookup rootOutside represented noDepth noFuel
        rw [valueRun] at run'
        cases run'
        obtain ⟨stored, storedDef⟩ :
            ∃ stored, stored = dictPut InPlaceSemantics.entryKey ys k (.record [.int k, w]) := ⟨_, rfl⟩
        rw [← storedDef] at heapRun
        obtain ⟨as, mid, bs, ysEq, storedEq⟩ :=
          dictPut_split InPlaceSemantics.entryKey ys k (.record [.int k, w])
        rw [← storedDef] at storedEq
        have memStored : ∀ z ∈ stored, z ∈ ys ∨ z = .record [.int k, w] := by
          intro z member
          rw [storedDef] at member
          exact mem_dictPut member
        have valid : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
        have heapEq : (heapObserved (heapStored hs root ys stored) vs.kept.toList).heap =
            hs.heap.set! root stored := by
          rw [heapObserved_heap]; rfl
        have lookupNew : (hs.heap.set! root stored)[root]? = some stored := by simp [valid]
        have sizeEq : (hs.heap.set! root stored).size = hs.heap.size := by simp
        obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
        have agreeOld : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root stored)[c]? = hs.heap[c]? :=
          fun y member => element_agree_after_write represented0 lookup member
        have agreeW : ∀ c, Reaches hs.heap w (.ref c) → (hs.heap.set! root stored)[c]? = hs.heap[c]? :=
          fun c reach => lookup_set_other hs.heap root _ (fun same => itemApartRoot (same ▸ reach))
        have agreeItem : ∀ c, Reaches hs.heap (.record [.int k, w]) (.ref c) →
            (hs.heap.set! root stored)[c]? = hs.heap[c]? :=
          fun c reach => agreeW c (reaches_entry reach)
        have allocatedE : AllocatedFlatValue hs.heap (.record [.int k, w]) (.record [.int, entryType t]) :=
          entry_allocated allocatedN
        have shapedZ : ∀ z ∈ stored, AllocatedFlatValue (hs.heap.set! root stored) z (.record [.int, entryType t]) := by
          intro z member
          rcases memStored z member with old | rfl
          · exact allocated_of_agree (entriesShaped z old) (agreeOld z old)
          · exact allocated_of_agree allocatedE agreeItem
        have shapedNew : AllocatedFlatValue (hs.heap.set! root stored) (.ref root) (.list (.record [.int, entryType t])) :=
          .list root _ _ lookupNew shapedZ
        have rootApart : ∀ z ∈ stored, ¬ Reaches (hs.heap.set! root stored) z (.ref root) := by
          intro z member reach
          rcases memStored z member with old | rfl
          · exact no_element_reaches_root lookup old _ _ (Nat.le_refl _) _ _ represented0
              (reaches_of_agree_rev (agreeOld z old) reach)
          · exact itemApartRoot (reaches_entry (reaches_of_agree_rev agreeItem reach))
        have entryShapeOld := flatAbstract_entryRecord valueShape
        have entryShapeNew := flatAbstract_entryRecord shapeN
        have describedZ : ∀ z ∈ stored,
            Describes gamma (hs.heap.set! root stored) (.record [.scalar, value.join aN]) z := by
          intro z member
          rw [← entry_join value aN]
          rcases memStored z member with old | rfl
          · exact describes_join (allocated_of_agree (entriesShaped z old) (agreeOld z old)) entryShapeOld
              entryShapeNew (Or.inl (describes_of_agree (agreeOld z old) (entriesDescribed z old)))
          · exact describes_join (allocated_of_agree allocatedE agreeItem) entryShapeOld entryShapeNew
              (Or.inr (describes_of_agree agreeItem (entry_described describedN)))
        have tagsZ : ∀ z ∈ stored, ElementTags (hs.heap.set! root stored) (.record [.int, entryType t])
            (.record [.scalar, value.join aN]) z := by
          intro z member
          rw [← entry_join value aN]
          rcases memStored z member with old | rfl
          · exact elementTags_of_agree (elementTags_join (entryTags z old) entryShapeOld entryShapeNew)
              (agreeOld z old)
          · exact elementTags_of_agree (elementTags_join_right (entry_elementTags pairedN tagsN chainsN deepN)
              entryShapeOld entryShapeNew) agreeItem
        have lookup' : hs.heap[root]? = some (as ++ mid ++ bs) := by rw [← ysEq]; exact lookup
        have lookupNew' : (hs.heap.set! root stored)[root]? = some (as ++ .record [.int k, w] :: bs) := by
          rw [← storedEq]; exact lookupNew
        have agreeOld' : ∀ y ∈ as ++ mid ++ bs, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.set! root stored)[c]? = hs.heap[c]? :=
          fun y member => agreeOld y (by rw [ysEq]; exact member)
        have rootApart' : ∀ z ∈ as ++ .record [.int k, w] :: bs,
            ¬ Reaches (hs.heap.set! root stored) z (.ref root) :=
          fun z member => rootApart z (by rw [storedEq]; exact member)
        have oldCert := described.1.2 [] roots (.record [.scalar, value]) certificate (.ref root) rfl (.here _)
        have dput := dictPut_corresponds (heap := hs.heap) k lenO pointwise
          (fun y member => by
            obtain ⟨k', v, eq, _⟩ := entry_shape (entriesShaped y member)
            exact ⟨k', v, eq⟩)
          (entry_corresponds_intro (k := k) pairedN)
        rw [← storedDef] at dput
        have pairedNew : Corresponds (hs.heap.set! root stored)
            (.list (dictPut ValueSemantics.entryKey os k (.record [.int k, o]))) (.ref root) :=
          corresponds_list_of_elements lookupNew dput.1 (fun i o' y oi yi => by
            rcases memStored y (List.mem_of_getElem? yi) with old | rfl
            · exact corresponds_of_agree (agreeOld y old) (dput.2 i o' y oi yi)
            · exact corresponds_of_agree agreeItem (dput.2 i o' _ oi yi))
        have observedNew : obsTyped declarations
            (.list (dictPut ValueSemantics.entryKey os k (.record [.int k, o]))) (.dict t) = true :=
          obsTyped_dict_of_elements (fun o' member => by
            rcases mem_dictPut member with old | rfl
            · exact entriesTyped o' old
            · exact entry_observed observedN)
        refine ⟨.ref root, heapObserved (heapStored hs root ys stored) vs.kept.toList, gamma, heapRun, ?_,
          Nat.le_of_eq (by rw [heapEq, sizeEq]), by rw [heapEq]; exact pairedNew, ?_, observedNew,
          by rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew,
          by rw [heapEq]; exact shapedNew, .list _ _ _ _ _, .list _ _ _,
          by rw [heapEq]; exact tagsDeep_list lookupNew tagsZ⟩
        · rw [escapesEq]
          refine flatInvariant_heap_frame inv (hole := root) (footprint := footprint) afterSub
            (by rw [heapEq, sizeEq]; exact Nat.le_refl _) ⟨stored, by rw [heapEq]; exact lookupNew, ?_⟩
            (by rw [heapObserved_links]; exact inv.links) ?_ apart represented rootOutside
            (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) (fun _ _ _ => Iff.rfl)
            (by rw [heapEq, sizeEq]; exact inv.namingBound) inv.separating
            (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
            (observed_external (valueTicked vs) (heapStored hs root ys stored) inv.keptSize inv.external)
            (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapStored, inv.fuel])
            (fun _ escaped => escaped)
          · intro z member d reach
            rw [heapEq] at reach ⊢
            exact allocated_reach_bound (shapedZ z member) reach
          · intro c different
            rw [heapEq]
            exact lookup_set_other hs.heap root _ different
        · rw [heapEq]
          refine list_described_of_elements receiverNamed noUnk lookupNew shapedNew describedZ ?_ ?_
          · intro d
            obtain ⟨oldDeep, exclusive⟩ := Bool.and_eq_true_iff.mp d
            obtain ⟨deepI, sepI, overlapI⟩ := storeExclusive_facts exclusive
            have wNodup := nodup_of_deepExclusive allocatedN shapeN describedN deepI
              (pathsApart_of_separated inv.separating sepI)
            exact inserted_footprint_nodup lookup' lookupNew' represented0 agreeOld' agreeItem rootApart'
              (fun n o' fp rep => (oldCert n o' fp rep).1 oldDeep)
              (fun n o' fp rep => by
                obtain ⟨n', o'', fp', repW, rfl⟩ := represents_entry rep
                exact wNodup n' o'' _ repW)
              (fun y member c reachI reachY => by
                have yOld : y ∈ ys := by rw [ysEq]; exact member
                obtain ⟨k', v, rfl, _⟩ := entry_shape (entriesShaped y yOld)
                exact reach_apart_of_covers inv.separating shapeN valueShape describedN.1.1
                  (covers_entry_value (entriesDescribed _ yOld).1.1) (cellOverlap_union_right_false overlapI).2 c
                  (reaches_entry reachI) (reaches_entry reachY))
          · intro sp
            have h := Bool.and_eq_true_iff.mp sp
            obtain ⟨oldSpine, spines⟩ := Bool.and_eq_true_iff.mp h.1
            have containersOk := h.2
            have wOnce := once_of_storeSpines inv.separating shapeN allocatedN describedN.1.1 spines
            exact inserted_footprint_once lookup' lookupNew' represented0 agreeOld' agreeItem rootApart'
              (fun n o' fp rep => (oldCert n o' fp rep).2 oldSpine)
              (fun n o' fp rep p c container located => by
                obtain ⟨p', rfl, locatedW⟩ := arrayAt_entry located
                obtain ⟨n', o'', fp', repW, rfl⟩ := represents_entry rep
                exact wOnce n' o'' _ repW p' c (containerPath_entry container) locatedW)
              (fun p c container located reachI => by
                cases located with
                | @element _ _ x _ _ lookup'' yMember inner =>
                  rw [lookup'] at lookup''
                  cases lookup''
                  have yOld : x ∈ ys := by rw [ysEq]; exact yMember
                  obtain ⟨k', v, rfl, shapedV⟩ := entry_shape (entriesShaped _ yOld)
                  obtain ⟨p', rfl, innerV⟩ := arrayAt_entry inner
                  obtain ⟨o', m', a'⟩ := (covers_entry_value (entriesDescribed _ yOld).1.1) p' c innerV
                  obtain ⟨cs, entry, inCs⟩ := mem_namesAt_of_arrayAt valueShape shapedV p' c o' innerV m'
                  exact cell_apart_of_covers inv.separating shapeN describedN.1.1 ⟨o', inCs, a'⟩
                    (containers_all_facts containersOk (p', cs)
                      (List.mem_filter.mpr ⟨entry, containerPath_entry container⟩)) (reaches_entry reachI))
              (fun p c container located y yMember reachY => by
                obtain ⟨p', rfl, locatedW⟩ := arrayAt_entry located
                obtain ⟨o', m', a'⟩ := describedN.1.1 p' c locatedW
                obtain ⟨cs, entry, inCs⟩ := mem_namesAt_of_arrayAt shapeN allocatedN p' c o' locatedW m'
                have disjoint := ((storeSpines_facts spines).2 (p', cs)
                  (List.mem_filter.mpr ⟨entry, containerPath_entry container⟩)).1
                have yOld : y ∈ ys := by rw [ysEq]; exact yMember
                obtain ⟨k', v, rfl, _⟩ := entry_shape (entriesShaped y yOld)
                exact cell_apart_of_covers inv.separating valueShape
                  (covers_entry_value (entriesDescribed _ yOld).1.1) ⟨o', inCs, a'⟩
                  (cellOverlap_union_right_false disjoint).2 (reaches_entry reachY))
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
      · have success := (dictInsert_runtime_success inv valueReceiver heapReceiver valueKey heapKey valueItem
          heapItem lookup rootOutside represented noDepth noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.Dictionary
