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

/-- Literal typing forces every operand type to the element type. -/
theorem primType_literal_success {t : Ty} {types : List Ty} {type : Ty}
    (run : primType (.literal t) types = .ok type) :
    type = .list t ∧ ∀ ty ∈ types, Ty.equal ty t = true := by
  unfold primType at run
  simp only at run
  split at run
  · rename_i allT
    refine ⟨(Except.ok.inj run).symm, ?_⟩
    intro ty member
    exact List.all_eq_true.mp allT ty member
  · change Except.error _ = Except.ok type at run
    contradiction

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
open Ownership.FlatFragment.VariableFacts

/-- Every live projected value stays described after an allocation or a
write step, under any naming that keeps the old names. -/
theorem described_flat_frame {next : Heap} {w w' : Value} {o : Observation} {gamma : Naming} {gamma' : Naming} {p : Path}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (agree : ∀ c, Reaches hs.heap w' (.ref c) → next[c]? = hs.heap[c]?)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (use : (x, p) ∈ live)
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (valuePath : projectVal w p = some w') (described : Describes gamma hs.heap (a.atPath p) w') :
    Describes gamma' next (a.atPath p) w' := by
  obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
  obtain ⟨t, o', w'', _, _, valuePath', _, shape'⟩ := inv.bindingsTyped x p use o w ty binding declared
  rw [valuePath] at valuePath'
  cases Option.some.inj valuePath'
  have below : ∀ c, Reaches next w' (.ref c) → c < hs.heap.size :=
    fun c r => allocated_reach_bound shape' (reaches_of_agree_rev agree r)
  exact describes_naming_same (allocated_of_agree shape' agree) namingSame below
    (describes_of_agree agree described)

/-- The immutable-path naming of every flat binding after any heap step. -/
theorem named_flat_frame {next : Heap} {w : Value} {o : Observation} {gamma : Naming} {gamma' : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (immutable : immutablePath q = true) (located : ArrayAt next w q c) :
    named gamma' (a.cellsAt q) c := by
  have before : ArrayAt hs.heap w q c := arrayAt_immutable_everywhere immutable located hs.heap
  have old := inv.named x o w a binding abstractBinding q c immutable before
  exact named_same_of_naming namingSame (inv.bindingsBounded x o w binding c (reaches_of_atPath before)) old

/-- The heap frame of the strengthened relation. The hole is the next
address at an allocation, or the written root at a write step. The live set
must avoid bindings of the hole; everything else is derived. -/
theorem flatInvariant_heap_frame {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    {vs' : ValueSemantics.State} {hs' : InPlaceSemantics.State} {gamma' : Naming}
    {live' : Live} {escapes' : List Origin} {hole : Nat} {footprint : List Nat}
    (liveSub : ∀ use ∈ live', use ∈ live)
    (sizeMono : hs.heap.size ≤ hs'.heap.size)
    (holeStored : ∃ xs, hs'.heap[hole]? = some xs ∧
      ∀ x ∈ xs, ∀ d, Reaches hs'.heap x (.ref d) → d < hs'.heap.size)
    (links : hs'.links = [])
    (frame : ∀ c, c ≠ hole → hs'.heap[c]? = hs.heap[c]?)
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
    have different : address ≠ hole := fun same => observersApart (same ▸ member)
    exact frame address different
  have framed : RepresentsMany hs'.heap observationDepth hs'.kept.toList vs'.kept.toList footprint := by
    rw [keptSame, valueKeptSame]
    exact representsMany_frame represented footprintFrame
  have liveAgree : ∀ x p, (x, p) ∈ live' → ∀ o w w', env.lookup x = some (o, w) → projectVal w p = some w' →
      ∀ c, Reaches hs.heap w' (.ref c) → hs'.heap[c]? = hs.heap[c]? := by
    intro x p use o w w' binding valuePath c reach
    obtain ⟨q, located⟩ := arrayAt_of_reaches reach
    exact frame c (liveApart x p use o w w' binding valuePath q c located)
  have bindingsTyped' : ∀ x p, (x, p) ∈ live' → ∀ o w ty, env.lookup x = some (o, w) →
      tenv.lookup x = some ty →
      ∃ t o' w', tyAt ty p = some t ∧ projectObs o p = some o' ∧ projectVal w p = some w' ∧
        obsTyped declarations o' t = true ∧ AllocatedFlatValue hs'.heap w' t := by
    intro x p use o w ty binding declared
    obtain ⟨t, o', w', at_p, obsPath, valuePath, observed, shape⟩ :=
      inv.bindingsTyped x p (liveSub _ use) o w ty binding declared
    exact ⟨t, o', w', at_p, obsPath, valuePath, observed,
      allocated_of_agree shape (liveAgree x p use o w w' binding valuePath)⟩
  have bindingsBounded' : ∀ x o w, env.lookup x = some (o, w) →
      ∀ c, Reaches hs'.heap w (.ref c) → c < hs'.heap.size := by
    intro x o w binding c reach
    obtain ⟨stored, holeAt, storedBounded⟩ := holeStored
    rcases reaches_split_at_hole holeAt frame reach with before | ⟨z, zMember, zReach⟩
    · exact Nat.lt_of_lt_of_le (inv.bindingsBounded x o w binding c before) sizeMono
    · exact storedBounded z zMember c zReach
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
    links := links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := bindingsTyped'
    bindingsBounded := bindingsBounded'
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
    exact ⟨o', w', observationPath, valuePath,
      corresponds_of_agree (liveAgree x p use o w w' binding valuePath) paired⟩
  · intro x p use o w a w' binding abstractBinding valuePath
    exact described_flat_frame inv (liveAgree x p use o w w' binding valuePath) namingSame (liveSub _ use)
      binding abstractBinding valuePath (inv.described x p (liveSub _ use) o w a w' binding abstractBinding valuePath)
  · intro x o w a binding abstractBinding q c immutable located
    exact named_flat_frame inv namingSame binding abstractBinding immutable located

end Ownership.FlatFragment.HeapFrame
