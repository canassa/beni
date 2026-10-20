import Ownership.FlatFragment.Fields

/-! The first flat fragment: operand lists and the heap frame of the relation. -/

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
open Ownership.FlatFragment.Runtime Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Fields

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

/-- Every integer-typed operand list runs to integers on both sides and
to scalars in the checker. -/
theorem flat_atoms_integers {args : List Atom} {types : List Ty} {tenv : Env Ty} {declarations : List Decl}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
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
      ih restTyped (fun ty member => ints ty (by simp [member]))
        (fun atom member => covered atom (by simp [member]))
    obtain ⟨integer, valueHead, heapHead, abstractHead⟩ :=
      flat_atom_integer inv headTyped (covered atom (by simp))
    refine ⟨integer :: integers, ?_, ?_, ?_⟩
    · exact except_mapM_cons valueHead valueRest
    · exact except_mapM_cons heapHead heapRest
    · exact except_mapM_cons abstractHead abstractRest

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
open Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.AtomPreservation Ownership.FlatFragment.Fields Ownership.FlatFragment.Observe

/-- Every live projected value stays described in any flat heap that keeps
its roots allocated, under any naming that keeps the old names. -/
theorem described_flat_frame {next : Heap} {w w' : Value} {o : Observation} {gamma : Naming} {gamma' : Naming} {p : Path}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (nextFlat : FlatHeap next) (size : hs.heap.size ≤ next.size)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (use : (x, p) ∈ live)
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (valuePath : projectVal w p = some w') (described : Describes gamma hs.heap (a.atPath p) w') :
    Describes gamma' next (a.atPath p) w' := by
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have tags := inv.tags x ty a o w declared abstractBinding binding
  have shape := allocated_shape_of_typed (inv.types x ty declared) actualTyped tags
  obtain ⟨t, at_p⟩ := inv.liveTyped x p ty use declared
  have shape' := allocated_project shape at_p valuePath
  have shape0 := inv.abstractShapes x ty a declared abstractBinding
  exact describes_flat_frame shape' (flatAbstract_atPath shape0 at_p)
    (resultTags_project tags shape0 at_p valuePath) inv.heapInts nextFlat size namingSame described

/-- The immutable-path naming of every flat binding in any flat heap. -/
theorem named_flat_frame {next : Heap} {w : Value} {o : Observation} {gamma : Naming} {gamma' : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (nextFlat : FlatHeap next) (size : hs.heap.size ≤ next.size)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (located : ArrayAt next w q c) :
    named gamma' (a.cellsAt q) c := by
  obtain ⟨ty, declared, _, actualTyped⟩ := inv.bindingsTyped x o w binding
  have shape := allocated_shape_of_typed (inv.types x ty declared) actualTyped
    (inv.tags x ty a o w declared abstractBinding binding)
  obtain ⟨_, immutable, everywhere⟩ := arrayAt_flat (allocated_mono shape size) nextFlat located
  have old := inv.named x o w a binding abstractBinding q c immutable (everywhere hs.heap)
  exact named_same_of_naming namingSame (arrayAt_flat shape inv.heapInts (everywhere hs.heap)).1 old

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
    (liveApart : ∀ x p, (x, p) ∈ live' → ∀ o w w', env.lookup x = some (o, w) →
      projectVal w p = some w' → ∀ q c, ArrayAt hs.heap w' q c → c ≠ hole)
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
      linksValid := Soundness.linksValid_of_empty _ (links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (links)
    }
    heapInts := nextFlat
    links := links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := bindingsTyped_after_flat_heap inv nextFlat size
    tags := inv.tags
    chains := inv.chains
    liveTyped := fun x p ty member declared => inv.liveTyped x p ty (liveSub _ member) declared
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
    obtain ⟨a, abstractBinding⟩ :=
      Ownership.FlatFragment.VariableFacts.lookup_exists_of_same_keys aenv env inv.abstractKeys.symm binding
    have shape := allocated_shape_of_typed (inv.types x ty declared) actualTyped
      (inv.tags x ty a o w declared abstractBinding binding)
    obtain ⟨t, at_p⟩ := inv.liveTyped x p ty (liveSub _ use) declared
    have shape' := allocated_project shape at_p valuePath
    refine ⟨o', w', observationPath, valuePath, ?_⟩
    refine corresponds_flat_frame shape' inv.heapInts ?_ paired
    intro q c located
    have bound := (arrayAt_flat shape' inv.heapInts located).1
    exact frame c bound (liveApart x p use o w w' binding valuePath q c located)
  · intro x p use o w a w' binding abstractBinding valuePath
    exact described_flat_frame inv nextFlat size namingSame (liveSub _ use) binding abstractBinding
      valuePath (inv.described x p (liveSub _ use) o w a w' binding abstractBinding valuePath)
  · intro x o w a binding abstractBinding q c _ located
    exact named_flat_frame inv nextFlat size namingSame binding abstractBinding located

end Ownership.FlatFragment.HeapFrame
