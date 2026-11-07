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

/-- A projection reads the heap only at the arrays on its route: the record
objects whose slot it enters (#316). A heap that keeps those arrays keeps the
projection. -/
theorem projectHeap_agree {heap next : Heap} :
    ∀ {w : Value} {p : Path},
      (∀ q c rest, p = q ++ .element :: rest → ArrayAt heap w q c → next[c]? = heap[c]?) →
      projectHeap next w p = projectHeap heap w p := by
  intro w p
  induction p generalizing w with
  | nil => intro _; simp [projectHeap]
  | cons step rest ih =>
    intro agree
    cases step with
    | field i =>
      cases w with
      | record ws =>
        simp only [projectHeap]
        cases found : ws[i]? with
        | none => rfl
        | some x =>
          exact ih (fun q c rest' eq located => agree (.field i :: q) c rest'
            (by rw [eq]; rfl) (.field found located))
      | _ => simp [projectHeap]
    | element =>
      cases w with
      | ref c =>
        have same := agree [] c rest rfl (.here _)
        simp only [projectHeap, same]
        cases found : heap[c]? with
        | none => rfl
        | some xs =>
          match xs, found with
          | [.record ys], found =>
            exact ih (fun q d rest' eq located => agree (.element :: q) d rest'
              (by rw [eq]; rfl) (.element found (by simp) located))
          | [], _ => rfl
          | [.int _], _ => rfl
          | [.ref _], _ => rfl
          | [.closure _ _], _ => rfl
          | a :: _ :: _, _ => cases a <;> rfl
      | _ => simp [projectHeap]
    | _ => cases w <;> simp [projectHeap]

/-- Every live projected value stays described after an allocation or a
write step, under any naming that keeps the old names. -/
theorem described_flat_frame {next : Heap} {w w' : Value} {o : Observation} {gamma : Naming} {gamma' : Naming} {p : Path}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (agree : ∀ c, Reaches hs.heap w' (.ref c) → next[c]? = hs.heap[c]?)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (use : (x, p) ∈ live)
    (binding : env.lookup x = some (o, w)) (abstractBinding : aenv.lookup x = some a)
    (valuePath : projectHeap hs.heap w p = some w') {b : Abstract} (described : Describes gamma hs.heap b w') :
    Describes gamma' next b w' := by
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

/-- The heap frame of the strengthened relation. The changed arrays are
`inside`: the next address at an allocation, the written array at a plain
write, and the written array's link component at a linked write (#169). The
live set's projected values and the observers must avoid them, and every
live projection reads the same value in the next heap (`projected`): it does
when its route avoids them (`projected_of_route`), and an update keeps the
slot's kept fields (#316). The links must be valid and closed under the new
naming; everything else is derived. -/
theorem flatInvariant_heap_frame {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    {vs' : ValueSemantics.State} {hs' : InPlaceSemantics.State} {gamma' : Naming}
    {live' : Live} {escapes' : List Origin} {inside : Nat → Prop} {footprint : List Nat}
    (liveSub : ∀ use ∈ live', use ∈ live)
    (sizeMono : hs.heap.size ≤ hs'.heap.size)
    (linksValid : LinksValid hs') (linkClosed : Ownership.LinkClauses.LinkClosed hs'.links gamma')
    (frame : ∀ c, ¬ inside c → hs'.heap[c]? = hs.heap[c]?)
    (liveApart : ∀ x p, (x, p) ∈ live' → ∀ o w w', env.lookup x = some (o, w) →
      projectHeap hs.heap w p = some w' → ∀ q c, ArrayAt hs.heap w' q c → ¬ inside c)
    (projected : ∀ x p, (x, p) ∈ live' → ∀ o w, env.lookup x = some (o, w) →
      projectHeap hs'.heap w p = projectHeap hs.heap w p)
    (represented : RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint)
    (observersApart : ∀ c ∈ footprint, ¬ inside c)
    (keptSame : hs'.kept = hs.kept) (valueKeptSame : vs'.kept = vs.kept)
    (namingSame : ∀ origin cell, cell < hs.heap.size → (cell ∈ gamma' origin ↔ cell ∈ gamma origin))
    (bounded : NamingBound gamma' hs'.heap.size) (separating : Separating gamma')
    (reads : vs'.reads = hs'.reads) (external : vs'.externalReads = hs'.externalReads)
    (fuel : vs'.fuel = hs'.fuel)
    (escapesMono : ∀ origin, Escaped escapes origin → Escaped escapes' origin)
    (heapKinds : ∃ kinds, StateKinded kinds hs' env tenv) :
    FlatInvariant declarations vs' hs' env live' aenv tenv escapes' gamma' := by
  have footprintFrame : ∀ address ∈ footprint, hs'.heap[address]? = hs.heap[address]? :=
    fun address member => frame address (observersApart address member)
  have framed : RepresentsMany hs'.heap observationDepth hs'.kept.toList vs'.kept.toList footprint := by
    rw [keptSame, valueKeptSame]
    exact representsMany_frame represented footprintFrame
  have liveAgree : ∀ x p, (x, p) ∈ live' → ∀ o w w', env.lookup x = some (o, w) → projectHeap hs.heap w p = some w' →
      ∀ c, Reaches hs.heap w' (.ref c) → hs'.heap[c]? = hs.heap[c]? := by
    intro x p use o w w' binding valuePath c reach
    obtain ⟨q, located⟩ := arrayAt_of_reaches reach
    exact frame c (liveApart x p use o w w' binding valuePath q c located)
  have bindingsTyped' : ∀ x p, (x, p) ∈ live' → ∀ o w ty, env.lookup x = some (o, w) →
      tenv.lookup x = some ty →
      ∃ t o' w', tyAt ty p = some t ∧ projectObs o p = some o' ∧ projectHeap hs'.heap w p = some w' ∧
        obsTyped declarations o' t = true ∧ AllocatedFlatValue hs'.heap w' (entryType t) := by
    intro x p use o w ty binding declared
    obtain ⟨t, o', w', at_p, obsPath, valuePath, observed, shape⟩ :=
      inv.bindingsTyped x p (liveSub _ use) o w ty binding declared
    exact ⟨t, o', w', at_p, obsPath, by rw [projected x p use o w binding]; exact valuePath, observed,
      allocated_of_agree shape (liveAgree x p use o w w' binding valuePath)⟩
  have bindingsBounded' : ∀ x o w, env.lookup x = some (o, w) →
      ∀ c, Reaches hs'.heap w (.ref c) → c < hs'.heap.size := by
    intro x o w binding c reach
    obtain ⟨kinds, state⟩ := heapKinds
    obtain ⟨ty, declared⟩ := lookup_exists_of_same_keys tenv env inv.typeKeys.symm binding
    exact state.reach_bound (state.env x ty o w declared binding) reach
  -- The certificate of an object's live fields (#316): the fields that a live
  -- use reads through the slot are the old ones, and their arrays are apart
  -- from the change.
  have objects' : ∀ x o w a q c roots e ex ws, env.lookup x = some (o, w) → aenv.lookup x = some a →
      (∀ s ∈ q, ∃ i, s = Step.field i) → projectHeap hs'.heap w q = some (.ref c) →
      a.atPath q = .list roots e ex → hs'.heap[c]? = some [.record ws] →
      ∀ keep : List Bool, (∀ g, keep[g]? = some true → (x, q ++ [.element, .field g]) ∈ live') →
      ∀ n os fps, RepresentsMany hs'.heap n (selectFields keep ws) os fps →
        (ex.deep = true → (c :: fps).Nodup) ∧
        (ex.spine = true → ∀ v ∈ selectFields keep ws, ∀ p d, containerPath p = true →
          ArrayAt hs'.heap v p d → (c :: fps).count d = 1) := by
    intro x o w a q c roots e ex ws binding found fields projectedQ at_q slot' keep liveKeep n os fps rep'
    by_cases anyKept : ∃ g : Nat, keep[g]? = some true
    · obtain ⟨g0, kept0⟩ := anyKept
      obtain ⟨_, v0, _, valuePath0, _⟩ := inv.bindings x _ (liveSub _ (liveKeep g0 kept0)) o w binding
      obtain ⟨c0, ws0, projected0, slot0, _⟩ := projectHeap_slot valuePath0
      have oldQ : projectHeap hs.heap w q = some (.ref c) := by
        rw [projectHeap_fields (heap' := hs'.heap) fields]; exact projectedQ
      rw [oldQ] at projected0
      cases projected0
      have agreeFields : ∀ g : Nat, keep[g]? = some true → ∃ v, ws[g]? = some v ∧ ws0[g]? = some v := by
        intro g kept
        have use := liveKeep g kept
        obtain ⟨_, vOld, _, valueOld, _⟩ := inv.bindings x _ (liveSub _ use) o w binding
        have valueNew : projectHeap hs'.heap w (q ++ [.element, .field g]) = some vOld := by
          rw [projected x _ use o w binding]; exact valueOld
        obtain ⟨c1, xs1, proj1, slot1, at1⟩ := projectHeap_slot valueNew
        rw [projectedQ] at proj1
        cases proj1
        rw [slot'] at slot1
        cases slot1
        obtain ⟨c2, xs2, proj2, slot2, at2⟩ := projectHeap_slot valueOld
        rw [oldQ] at proj2
        cases proj2
        rw [slot0] at slot2
        cases slot2
        exact ⟨vOld, at1, at2⟩
      have sameFields := selectFields_congr agreeFields
      -- the arrays of a kept field are apart from the change
      have agreeKept : ∀ v ∈ selectFields keep ws0, ∀ d, Reaches hs.heap v (.ref d) → hs'.heap[d]? = hs.heap[d]? := by
        intro v member d reach
        obtain ⟨g, kept, at_g⟩ := mem_selectFields member
        have use := liveKeep g kept
        have valueOld : projectHeap hs.heap w (q ++ [.element, .field g]) = some v := by
          rw [projectHeap_append, oldQ]
          simp [projectHeap, slot0, at_g]
        obtain ⟨r, located⟩ := arrayAt_of_reaches reach
        exact frame d (liveApart x _ use o w v binding valueOld r d located)
      rw [sameFields] at rep' ⊢
      have repOld := representsMany_of_agree_rev agreeKept rep'
      obtain ⟨deep, spine⟩ := inv.objectsCertified x o w a q c roots e ex ws0 binding found fields oldQ at_q
        slot0 keep (fun g kept => liveSub _ (liveKeep g kept)) n os fps repOld
      refine ⟨deep, fun certified v member p d container located => ?_⟩
      exact spine certified v member p d container
        (atPath_of_agree_rev (agreeKept v member) located)
    · have empty : selectFields keep ws = [] :=
        selectFields_nil_of_none (fun g kept => anyKept ⟨g, kept⟩)
      rw [empty] at rep' ⊢
      cases rep'
      exact ⟨fun _ => by simp, fun _ v member => by simp at member⟩
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
      linksValid := linksValid
      linkNamed := Ownership.LinkClauses.linkNamed_of_closed linkClosed
    }
    linkClosed := linkClosed
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := bindingsTyped'
    deepTags := by
      intro x p use o w ty a t w' binding declared abstractBinding at_p valuePath
      rw [projected x p use o w binding] at valuePath
      exact tagsDeep_of_agree
        (inv.deepTags x p (liveSub _ use) o w ty a t w' binding declared abstractBinding at_p valuePath)
        (liveAgree x p use o w w' binding valuePath)
    bindingsBounded := bindingsBounded'
    tags := inv.tags
    chains := inv.chains
    liveTyped := fun x p ty member declared => inv.liveTyped x p ty (liveSub _ member) declared
    namingBound := bounded
    observers := ⟨footprint, framed⟩
    heapKinds := heapKinds
    observationsTyped := inv.observationsTyped
    objectsCertified := objects'
    liveTags := by
      intro x p use o w ty a t o' w' binding declared abstractBinding at_p obsPath valuePath
      rw [projected x p use o w binding] at valuePath
      exact inv.liveTags x p (liveSub _ use) o w ty a t o' w' binding declared abstractBinding at_p obsPath valuePath
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
    exact ⟨o', w', observationPath, by rw [projected x p use o w binding]; exact valuePath,
      corresponds_of_agree (liveAgree x p use o w w' binding valuePath) paired⟩
  · intro x p use o w a ty w' binding abstractBinding declared valuePath
    rw [projected x p use o w binding] at valuePath
    exact described_flat_frame inv (liveAgree x p use o w w' binding valuePath) namingSame (liveSub _ use)
      binding abstractBinding valuePath
      (inv.toInvariant.described x p (liveSub _ use) o w a ty w' binding abstractBinding declared valuePath)
  · intro x o w a binding abstractBinding q c immutable located
    exact named_flat_frame inv namingSame binding abstractBinding immutable located

/-- A live projection whose route avoids the changed arrays reads the same
value in the next heap. -/
theorem projected_of_route {heap next : Heap} {inside : Nat → Prop} {env : List (Var × Observation × Value)}
    {live : Live}
    (frame : ∀ c, ¬ inside c → next[c]? = heap[c]?)
    (routeApart : ∀ x p, (x, p) ∈ live → ∀ o w q c rest, env.lookup x = some (o, w) →
      p = q ++ .element :: rest → ArrayAt heap w q c → ¬ inside c) :
    ∀ x p, (x, p) ∈ live → ∀ o w, env.lookup x = some (o, w) →
      projectHeap next w p = projectHeap heap w p :=
  fun x p use o w binding => projectHeap_agree fun q c rest eq located =>
    frame c (routeApart x p use o w q c rest binding eq located)

/-- An allocation keeps every live projection: the route's objects are
allocated already. -/
theorem projected_after_alloc {declarations : List Decl} {vs : ValueSemantics.State}
    {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live}
    {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    {next : Heap} {stored : List Value} (heapEq : next = hs.heap.push stored) (live' : Live) :
    ∀ x p, (x, p) ∈ live' → ∀ o w, env.lookup x = some (o, w) →
      projectHeap next w p = projectHeap hs.heap w p := by
  refine projected_of_route (inside := (· = hs.heap.size)) (fun c different => ?_) ?_
  · rw [heapEq]
    simp [Array.getElem?_push, show c ≠ hs.heap.size from different]
  · intro x p _ o w q c rest binding _ located same
    have := live_path_route_below inv x o w q c binding located
    omega

end Ownership.FlatFragment.HeapFrame
