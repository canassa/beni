import Ownership.FlatFragment.Reach

/-! The first flat fragment: operand lists, the list receiver, and the heap frame of the relation. -/

/-! operand facts for the flat primitive cases.
Each operand list fact follows from the actual per-atom runs and the real
`List.mapM` equations. The receiver fact follows the prefix relation: typed
bindings, key alignment, live correspondence, and the named root.
No final interpreter agreement or separate permission predicate enters.
-/

namespace Ownership.FlatFragment.Atoms

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Support
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.Env Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.Runtime Ownership.FlatFragment.CheckerExtraction

/-- A successful `Except` map over a cons cell runs the head and the tail. -/
theorem except_mapM_cons_success {α : Type} {β : Type} {f : α → Except String β} {head : α} {tail : List α}
    {results : List β}
    (run : (head :: tail).mapM f = .ok results) :
    ∃ first rest, f head = .ok first ∧ tail.mapM f = .ok rest ∧ results = first :: rest := by
  rw [List.mapM_cons] at run
  obtain ⟨first, headRun, next⟩ := except_bind_success run
  obtain ⟨rest, tailRun, returned⟩ := except_bind_success next
  change Except.ok (first :: rest) = Except.ok results at returned
  exact ⟨first, rest, headRun, tailRun, (Except.ok.inj returned).symm⟩

theorem except_mapM_nil_success {α : Type} {β : Type} {f : α → Except String β} {results : List β}
    (run : ([] : List α).mapM f = .ok results) : results = [] := by
  rw [List.mapM_nil] at run
  change Except.ok [] = Except.ok results at run
  exact (Except.ok.inj run).symm

theorem except_mapM_cons {α : Type} {β : Type} {f : α → Except String β} {head : α} {tail : List α}
    {first : β} {rest : List β}
    (headRun : f head = .ok first) (tailRun : tail.mapM f = .ok rest) :
    (head :: tail).mapM f = .ok (first :: rest) := by
  rw [List.mapM_cons]
  simp [headRun, tailRun, bind, Except.bind, pure, Except.pure]

/-- The exact typing equation of a primitive expression. -/
theorem exprType_prim_success {args : List Atom} {op : Prim} {type : Ty} {self : Decl} {tenv : Env Ty} {declarations : List Decl}
    (run : exprType declarations self tenv (.prim op args) = .ok type) :
    ∃ types, args.mapM (atomType tenv) = .ok types ∧ primType op types = .ok type := by
  change (args.mapM (atomType tenv) >>= fun types => primType op types) = .ok type at run
  exact except_bind_success run

theorem ty_equal_int (equal : (ty == Ty.int) = true) : ty = .int := by
  cases ty <;> simp [BEq.beq, Ty.equal] at equal ⊢

theorem int_equal_ty (equal : (Ty.int == ty) = true) : ty = .int := by
  cases ty <;> simp [BEq.beq, Ty.equal] at equal ⊢

/-- Integer literal typing forces every operand type to `Int`. -/
theorem primType_literal_int_success {types : List Ty} {type : Ty}
    (run : primType (.literal .int) types = .ok type) :
    type = .list .int ∧ ∀ ty ∈ types, ty = .int := by
  unfold primType at run
  simp only at run
  split at run
  · rename_i allInt
    refine ⟨(Except.ok.inj run).symm, ?_⟩
    intro ty member
    exact ty_equal_int (List.all_eq_true.mp allInt ty member)
  · change Except.error _ = Except.ok type at run
    contradiction

/-- Every integer-typed flat operand list runs to integers on both sides and
to scalars in the checker. -/
theorem flat_atoms_integers {args : List Atom} {types : List Ty} {tenv : Env Ty} {declarations : List Decl}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (flat : ∀ atom ∈ args, FlatAtom atom)
    (typed : args.mapM (atomType tenv) = .ok types)
    (ints : ∀ ty ∈ types, ty = .int)
    (covered : ∀ atom ∈ args, ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ integers : List Int,
      args.mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) = .ok (valueInts integers) ∧
      args.mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) = .ok (heapInts integers) ∧
      args.mapM (m := Except String) (abstractAtom aenv) = .ok (args.map fun _ => Abstract.scalar) := by
  induction args generalizing types with
  | nil =>
    exact ⟨[], rfl, rfl, rfl⟩
  | cons atom rest ih =>
    obtain ⟨headType, restTypes, headTyped, restTyped, shape⟩ := except_mapM_cons_success typed
    subst shape
    have headInt : headType = .int := ints headType (by simp)
    subst headInt
    obtain ⟨integers, valueRest, heapRest, abstractRest⟩ :=
      ih (fun atom member => flat atom (by simp [member])) restTyped
        (fun ty member => ints ty (by simp [member]))
        (fun atom member => covered atom (by simp [member]))
    obtain ⟨integer, valueHead, heapHead, abstractHead⟩ :=
      flat_atom_integer inv (flat atom (by simp)) headTyped (covered atom (by simp))
    refine ⟨integer :: integers, ?_, ?_, ?_⟩
    · exact except_mapM_cons valueHead valueRest
    · exact except_mapM_cons heapHead heapRest
    · exact except_mapM_cons abstractHead abstractRest

/-- A flat list-typed operand is a variable whose binding is an allocated
integer array. The live use supplies the exact observation. The prefix
relation supplies the named root and the flat abstract shape. -/
theorem flat_atom_list {tenv : Env Ty} {atom : Atom} {declarations : List Decl}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (flat : FlatAtom atom)
    (typed : atomType tenv atom = .ok (.list .int))
    (covered : ∀ use ∈ atomUses atom, use ∈ live) :
    ∃ (key root : Nat) (integers : List Int) (roots : List Origin) (element : Abstract)
      (certificate : Certificate),
      atom = .var key ∧
      env.lookup key = some (.list (valueInts integers), .ref root) ∧
      aenv.lookup key = some (.list roots element certificate) ∧
      tenv.lookup key = some (.list .int) ∧
      hs.heap[root]? = some (heapInts integers) ∧
      named gamma roots root ∧
      (element = .bottom ∨ element = .scalar) ∧
      ValueSemantics.atom (valueEnv env) atom = .ok (.list (valueInts integers)) ∧
      InPlaceSemantics.atom (heapEnv env) atom = .ok (.ref root) ∧
      abstractAtom aenv atom = .ok (.list roots element certificate) := by
  cases flat with
  | int integer =>
    change Except.ok Ty.int = Except.ok (Ty.list .int) at typed
    cases Except.ok.inj typed
  | var key =>
    have typeRun : lookup tenv key = .ok (.list .int) := by simpa only [atomType] using typed
    have declared := lookup_option_of_success typeRun
    obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env tenv inv.typeKeys declared
    rcases pair with ⟨observation, actual⟩
    obtain ⟨abstract, abstractBinding⟩ :=
      lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
    have shape := inv.abstractShapes key (.list .int) abstract declared abstractBinding
    obtain ⟨type, actualDeclared, _, actualTyped⟩ :=
      inv.bindingsTyped key observation actual binding
    have sameType : type = .list .int := Option.some.inj (actualDeclared.symm.trans declared)
    subst type
    cases allocated_shape_of_typed FlatType.listInt actualTyped with
    | list root allocated =>
      have lookupRoot : hs.heap[root]? = some hs.heap[root] := by simp [allocated]
      obtain ⟨integers, payload⟩ := integers_of_flat_values hs.heap[root] (inv.heapInts root _ lookupRoot)
      rw [payload] at lookupRoot
      have use : (key, []) ∈ live := covered (key, []) (by simp [atomUses])
      have paired := (live_variable_result inv use binding abstractBinding).1
      have observed := observation_of_integer_ref lookupRoot paired
      subst observed
      obtain ⟨valueAtom, heapAtom⟩ := variable_atoms_run binding
      cases shape with
      | listBottom roots certificate =>
        refine ⟨key, root, integers, roots, .bottom, certificate, rfl, binding, abstractBinding,
          declared, lookupRoot, named_root_from_invariant inv binding abstractBinding, Or.inl rfl,
          valueAtom, heapAtom, ?_⟩
        simp [abstractAtom, lookup, abstractBinding]
      | listScalar roots certificate =>
        refine ⟨key, root, integers, roots, .scalar, certificate, rfl, binding, abstractBinding,
          declared, lookupRoot, named_root_from_invariant inv binding abstractBinding, Or.inr rfl,
          valueAtom, heapAtom, ?_⟩
        simp [abstractAtom, lookup, abstractBinding]

end Ownership.FlatFragment.Atoms

/-! heap frame for the strengthened flat relation.
A heap change that keeps every old cell except one hole, keeps the complete
observer footprint, and keeps the naming of old cells preserves the relation
on a live set whose bindings avoid that hole. Allocation is the case where
the hole is the next address; a counted write is the case where the hole is
the written receiver. Dead aliases of the hole keep their types, not their
observations. No theorem uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.HeapFrame

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.HeapPreservation
open Ownership.FlatFragment.RepresentsDepth Ownership.FlatFragment.FiniteReach Ownership.FlatFragment.FiniteReachFrame
open Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Runtime Ownership.FlatFragment.Description
open Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.AtomPreservation

theorem observation_depth_pos (observation : Observation) : 0 < observation.depth := by
  cases observation <;> simp [Observation.depth] <;> omega

/-- Flat runtime values have no field path. -/
theorem projectVal_flat {heap : Heap} {w : Value} {w' : Value} {p : Path} {ty : Ty} (shape : AllocatedFlatValue heap w ty)
    (projected : projectVal w p = some w') : p = [] ∧ w' = w := by
  cases shape with
  | int integer =>
    cases p with
    | nil => exact ⟨rfl, (Option.some.inj projected).symm⟩
    | cons step rest => cases step <;> simp [projectVal] at projected
  | list root allocated =>
    cases p with
    | nil => exact ⟨rfl, (Option.some.inj projected).symm⟩
    | cons step rest => cases step <;> simp [projectVal] at projected

theorem obs_flat_shape {o : Observation} {ty : Ty} (flatType : FlatType ty) (typed : obsTyped declarations o ty = true) :
    (∃ integer, o = .int integer) ∨ (∃ items, o = .list items) := by
  cases flatType <;> cases o <;> simp [obsTyped] at typed ⊢

/-- Flat observations have no field path. -/
theorem projectObs_flat {o : Observation} {o' : Observation} {p : Path} {ty : Ty} (flatType : FlatType ty) (typed : obsTyped declarations o ty = true)
    (projected : projectObs o p = some o') : p = [] ∧ o' = o := by
  rcases obs_flat_shape flatType typed with ⟨integer, rfl⟩ | ⟨items, rfl⟩
  · cases p with
    | nil => exact ⟨rfl, (Option.some.inj projected).symm⟩
    | cons step rest => cases step <;> simp [projectObs] at projected
  · cases p with
    | nil => exact ⟨rfl, (Option.some.inj projected).symm⟩
    | cons step rest => cases step <;> simp [projectObs] at projected

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

/-- Every allocated flat binding is described in any flat heap that keeps
its root allocated, under any naming that keeps its root's old names. -/
theorem described_flat_frame {next : Heap} {w : Value} {o : Observation} {gamma : Naming} {gamma' : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (nextFlat : FlatHeap next) (size : hs.heap.size ≤ next.size)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a) :
    Describes gamma' next a w := by
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have flatType := inv.types x ty declared
  have shape := inv.abstractShapes x ty a declared abstractBinding
  cases allocated_shape_of_typed flatType actualTyped with
  | int integer =>
    cases shape with
    | int => exact integer_described integer
  | list root allocated =>
    have nextAllocated : root < next.size := Nat.lt_of_lt_of_le allocated size
    have lookupRoot : next[root]? = some next[root] := by simp [nextAllocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values next[root] (nextFlat root _ lookupRoot)
    rw [payload] at lookupRoot
    cases shape with
    | listBottom roots certificate =>
      exact allocated_list_described lookupRoot (named_same_of_naming namingSame allocated
        (named_root_from_invariant inv binding abstractBinding))
    | listScalar roots certificate =>
      exact allocated_list_described lookupRoot (named_same_of_naming namingSame allocated
        (named_root_from_invariant inv binding abstractBinding))

/-- The immutable-path naming of every flat binding in any flat heap. -/
theorem named_flat_frame {next : Heap} {w : Value} {o : Observation} {gamma : Naming} {gamma' : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (nextFlat : FlatHeap next) (size : hs.heap.size ≤ next.size)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (located : ArrayAt next w q c) :
    named gamma' (a.cellsAt q) c := by
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have flatType := inv.types x ty declared
  cases allocated_shape_of_typed flatType actualTyped with
  | int integer => cases located
  | list root allocated =>
    have nextAllocated : root < next.size := Nat.lt_of_lt_of_le allocated size
    have lookupRoot : next[root]? = some next[root] := by simp [nextAllocated]
    obtain ⟨integers, payload⟩ := integers_of_flat_values next[root] (nextFlat root _ lookupRoot)
    rw [payload] at lookupRoot
    obtain ⟨pathNil, sameRoot⟩ := arrayAt_flat_ref lookupRoot located
    subst pathNil
    rw [sameRoot]
    have old := inv.named x o (.ref root) a binding abstractBinding [] root rfl (.here _)
    exact named_same_of_naming namingSame allocated old

theorem representsMany_index {heap : Heap} {w : Value} {o : Observation} {i : Nat} (values : List Value)
    (represented : RepresentsMany heap depth values observations footprint)
    (valueAt : values[i]? = some w) (observationAt : observations[i]? = some o) :
    ∃ cells, Represents heap depth w o cells := by
  induction values generalizing observations footprint i with
  | nil => simp at valueAt
  | cons head tail ih =>
    cases represented with
    | cons first rest =>
      cases i with
      | zero =>
        simp only [List.getElem?_cons_zero, Option.some.injEq] at valueAt observationAt
        subst valueAt
        subst observationAt
        exact ⟨_, first⟩
      | succ i =>
        exact ih rest (by simpa using valueAt) (by simpa using observationAt)

/-- The heap frame of the strengthened relation. The hole is the next
address at an allocation, or the written receiver at a counted write. The
live set must avoid bindings of the hole; everything else is derived. -/
theorem flatInvariant_heap_frame {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    {vs' : ValueSemantics.State} {hs' : InPlaceSemantics.State} {gamma' : Naming}
    {live' : Live} {escapes' : List Origin} {hole : Nat} {footprint : List Nat}
    (liveSub : ∀ use ∈ live', use ∈ live)
    (nextFlat : FlatHeap hs'.heap) (size : hs.heap.size ≤ hs'.heap.size) (links : hs'.links = [])
    (frame : ∀ c, c < hs.heap.size → c ≠ hole → hs'.heap[c]? = hs.heap[c]?)
    (liveApart : ∀ x p, (x, p) ∈ live' → ∀ o c, env.lookup x = some (o, .ref c) → c ≠ hole)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (observersApart : hole ∉ footprint)
    (keptSame : hs'.kept = hs.kept) (valueKeptSame : vs'.kept = vs.kept)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (bounded : NamingBound gamma' hs'.heap.size) (separating : Separating gamma')
    (reads : vs'.reads = hs'.reads) (external : vs'.externalReads = hs'.externalReads)
    (fuel : vs'.fuel = hs'.fuel)
    (escapesMono : ∀ origin, Escaped escapes origin → Escaped escapes' origin) :
    FlatInvariant declarations vs' hs' env live' aenv tenv escapes' gamma' := by
  have footprintFrame : ∀ address ∈ footprint, hs'.heap[address]? = hs.heap[address]? := by
    intro address member
    have bound := representsMany_bound represented address member
    have different : address ≠ hole := fun same => observersApart (same ▸ member)
    exact frame address bound different
  have framed : RepresentsMany hs'.heap observationDepth hs'.kept.toList vs'.kept.toList footprint := by
    rw [keptSame, valueKeptSame]
    exact representsMany_frame represented footprintFrame
  refine {
    toInvariant := {
      reads := reads
      external := external
      fuel := fuel
      keptSize := by rw [keptSame, valueKeptSame]; exact inv.keptSize
      kept := ?_
      keptEscaped := ?_
      bindings := ?_
      described := ?_
      named := ?_
      separating := separating
    }
    heapInts := nextFlat
    links := links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := bindingsTyped_after_flat_heap inv nextFlat size
    namingBound := bounded
    observers := ⟨footprint, framed⟩
  }
  · intro i o w valueAt heapAt
    have valueList : vs'.kept.toList[i]? = some o := by simpa using valueAt
    have heapList : hs'.kept.toList[i]? = some w := by simpa using heapAt
    obtain ⟨cells, witness⟩ := representsMany_index _ framed heapList valueList
    exact corresponds_of_represents witness
  · intro k member c reachable g names
    rw [keptSame] at member
    obtain ⟨observed, cells, witness, subset⟩ := representsMany_member represented member
    have before : Reaches hs.heap k (.ref c) :=
      reaches_before_of_frame witness
        (fun address present => footprintFrame address (subset address present)) reachable
    have inFootprint : c ∈ footprint := subset c (represents_reach_member witness before)
    have bound := representsMany_bound represented c inFootprint
    have old : c ∈ gamma g := (namingSame g c bound).mp names
    exact escapesMono g (inv.keptEscaped k member c before g old)
  · intro x p use o w binding
    obtain ⟨o', w', observationPath, valuePath, paired⟩ :=
      inv.bindings x p (liveSub _ use) o w binding
    obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
    have shape := allocated_shape_of_typed (inv.types x ty declared) actualTyped
    obtain ⟨pathNil, sameValue⟩ := projectVal_flat shape valuePath
    subst pathNil
    subst sameValue
    refine ⟨o', _, observationPath, valuePath, ?_⟩
    cases shape with
    | int integer => exact corresponds_int_frame paired
    | list root allocated =>
      have different : root ≠ hole := liveApart x [] use o root binding
      exact corresponds_ref_frame inv.heapInts allocated paired (frame root allocated different)
  · intro x p use o w a w' binding abstractBinding valuePath
    obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
    have shape := allocated_shape_of_typed (inv.types x ty declared) actualTyped
    obtain ⟨pathNil, sameValue⟩ := projectVal_flat shape valuePath
    subst pathNil
    subst sameValue
    exact described_flat_frame inv nextFlat size namingSame binding abstractBinding
  · intro x o w a binding abstractBinding q c _ located
    exact named_flat_frame inv nextFlat size namingSame binding abstractBinding located

end Ownership.FlatFragment.HeapFrame
