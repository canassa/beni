-- This module is the top of the proof import chain, not a leaf. It imports
-- every other proof and executable module, so that `FlatFragment/Support.lean`
-- and everything after it see one realization of each equation lemma: the
-- audit rejects an equation lemma that two modules realize (#182).
import Ownership.Soundness
import Ownership.BuilderProof
import Ownership.LinkedWriteFrame
import Ownership.KernelChecks
import Ownership.StatementChecks.ViewLinks
import Ownership.Report
import Ownership.Question
import Ownership.DiagnosticCampaign
import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures
import Ownership.Falsify
import Ownership.Enumerate
import Ownership.Cli
import Ownership.Bridge
import Ownership.Targeted

/-! The link clauses of the invariant (#169): what holds of `LinksValid` and
`LinkNamed` in another state with the same links, under allocation, under a
write that keeps every array nonempty, and when a view is made; and the
sufficient condition the step cases can establish, `LinkClosed`, the
unconditional per-link closure of a naming. Preservation of `LinkNamed`
under a successful `writeLinked` and under a call is not proved here. -/

namespace Ownership.LinkClauses

open InPlaceSemantics Soundness LinkedWriteFrame

/-! ## The same links in another state -/

theorem linksValid_of_same {hs hs' : State} (valid : LinksValid hs)
    (heap : hs'.heap = hs.heap) (links : hs'.links = hs.links) : LinksValid hs' :=
  ⟨by rw [links, heap]; exact valid.bounded, by rw [links, heap]; exact valid.sources,
   by rw [links]; exact valid.unique⟩

theorem linkNamed_of_same {hs hs' : State} {env : List (Var × Observation × Value)}
    {live : Live} {γ : Naming} (named : LinkNamed hs env live γ)
    (heap : hs'.heap = hs.heap) (links : hs'.links = hs.links) (kept : hs'.kept = hs.kept) :
    LinkNamed hs' env live γ := by
  intro c d connected guarded
  rw [links] at connected
  refine named c d connected ?_
  unfold Protected at guarded ⊢
  rw [heap, kept] at guarded
  exact guarded

/-! ## Allocation -/

theorem linksValid_push {hs : State} (valid : LinksValid hs) (xs : List Value) :
    LinksValid {hs with heap := hs.heap.push xs} := by
  refine ⟨?_, ?_, valid.unique⟩
  · intro v s front member
    obtain ⟨order, bound⟩ := valid.bounded v s front member
    simp only [Array.size_push]
    omega
  · intro v s front member
    obtain ⟨order, bound⟩ := valid.bounded v s front member
    obtain ⟨source, sourceLookup, nonempty⟩ := valid.sources v s front member
    refine ⟨source, ?_, nonempty⟩
    have different : s ≠ hs.heap.size := by omega
    simp [Array.getElem?_push, different, sourceLookup]

/-! ## A write that keeps every array nonempty -/

theorem linksValid_set {hs : State} (valid : LinksValid hs) (root : Nat) (xs : List Value)
    (nonempty : xs ≠ []) : LinksValid {hs with heap := hs.heap.set! root xs} := by
  refine ⟨?_, ?_, valid.unique⟩
  · intro v s front member
    simpa using valid.bounded v s front member
  · intro v s front member
    obtain ⟨source, sourceLookup, sourceNonempty⟩ := valid.sources v s front member
    by_cases same : s = root
    · subst same
      have bound : s < hs.heap.size := (Array.getElem?_eq_some_iff.mp sourceLookup).1
      exact ⟨xs, by simp [Array.getElem?_setIfInBounds_self_of_lt bound], nonempty⟩
    · exact ⟨source, by rw [HeapProof.lookup_set_other hs.heap root xs same]; exact sourceLookup,
        sourceNonempty⟩

/-! ## Making a view -/

/-- The state after `prim (.view front) [.ref c]` on a nonempty source: the
    view at the next address, linked to `c`. -/
def viewed (hs : State) (c : Nat) (front : Bool) (source : List Value) : State :=
  {hs with heap := hs.heap.push (viewOf front source), links := hs.links ++ [(hs.heap.size, c, front)]}

theorem linksValid_viewed {hs : State} (valid : LinksValid hs) (c : Nat) (front : Bool)
    (source : List Value) (lookup : hs.heap[c]? = some source) (nonempty : source ≠ []) :
    LinksValid (viewed hs c front source) := by
  have allocated : c < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  have fresh : hs.heap.size ∉ hs.links.map (·.1) := by
    intro member
    obtain ⟨link, linkMember, same⟩ := List.mem_map.mp member
    rcases link with ⟨v, s, f⟩
    obtain ⟨_, bound⟩ := valid.bounded v s f linkMember
    simp only at same
    omega
  refine ⟨?_, ?_, ?_⟩
  · intro v s f member
    simp only [viewed, List.mem_append, List.mem_singleton] at member
    rcases member with old | new
    · obtain ⟨order, bound⟩ := valid.bounded v s f old
      simp only [viewed, Array.size_push]
      omega
    · obtain ⟨rfl, rfl, rfl⟩ := new
      simp only [viewed, Array.size_push]
      omega
  · intro v s f member
    simp only [viewed, List.mem_append, List.mem_singleton] at member
    rcases member with old | new
    · obtain ⟨order, bound⟩ := valid.bounded v s f old
      obtain ⟨src, sourceLookup, srcNonempty⟩ := valid.sources v s f old
      refine ⟨src, ?_, srcNonempty⟩
      have different : s ≠ hs.heap.size := by omega
      simp [viewed, Array.getElem?_push, different, sourceLookup]
    · obtain ⟨rfl, rfl, rfl⟩ := new
      refine ⟨source, ?_, nonempty⟩
      have different : c ≠ hs.heap.size := by omega
      simp [viewed, Array.getElem?_push, different, lookup]
  · simp only [viewed, List.map_append, List.map_cons, List.map_nil]
    exact List.nodup_append.mpr ⟨valid.unique, List.nodup_cons.mpr ⟨by simp, List.nodup_nil⟩, by
      intro a aMember b bMember
      simp only [List.mem_singleton] at bMember
      subst bMember
      intro same
      exact fresh (same ▸ aMember)⟩

/-! ## The sufficient condition: per-link closure of the naming

The checker gives a view its source's origins and a fresh site
(`primitive`, `.view`), so a post-naming that names the view by exactly the
source's origins is always available in the main context. Such a naming is
closed on every link, which gives `LinkNamed` for every protection. -/

/-- Every stored link joins two arrays with the same origins. -/
def LinkClosed (links : List (Nat × Nat × Bool)) (γ : Naming) : Prop :=
  ∀ v s front, (v, s, front) ∈ links → ∀ o, v ∈ γ o ↔ s ∈ γ o

theorem linkConnected_same_origins {links : List (Nat × Nat × Bool)} {γ : Naming}
    (closed : LinkClosed links γ) {c d : Nat} (connected : LinkConnected links c d) :
    ∀ o, c ∈ γ o ↔ d ∈ γ o := by
  induction connected with
  | refl => intro o; exact Iff.rfl
  | edge member => exact closed _ _ _ member
  | symm _ ih => intro o; exact (ih o).symm
  | trans _ _ ih₁ ih₂ => intro o; exact (ih₁ o).trans (ih₂ o)

theorem linkNamed_of_closed {hs : State} {env : List (Var × Observation × Value)} {live : Live}
    {γ : Naming} (closed : LinkClosed hs.links γ) : LinkNamed hs env live γ :=
  fun _ _ connected _ => linkConnected_same_origins closed connected

theorem linkClosed_of_empty (links : List (Nat × Nat × Bool)) (γ : Naming) (empty : links = []) :
    LinkClosed links γ := by
  intro v s front member
  rw [empty] at member
  simp at member

/-- A naming that keeps every allocated array's origins keeps the closure,
    because every linked array is allocated. -/
theorem linkClosed_of_old {hs : State} {γ γ' : Naming} (valid : LinksValid hs)
    (closed : LinkClosed hs.links γ)
    (old : ∀ origin cell, cell < hs.heap.size → (cell ∈ γ' origin ↔ cell ∈ γ origin)) :
    LinkClosed hs.links γ' := by
  intro v s front member o
  obtain ⟨order, bound⟩ := valid.bounded v s front member
  rw [old o v bound, old o s (by omega)]
  exact closed v s front member o

/-- The naming after a view: the new address gets exactly the origins of its
    source, and every old array keeps its origins. -/
theorem linkClosed_viewed {hs : State} {γ γ' : Naming} (valid : LinksValid hs)
    (closed : LinkClosed hs.links γ) (c : Nat) (front : Bool)
    (old : ∀ origin cell, cell < hs.heap.size → (cell ∈ γ' origin ↔ cell ∈ γ origin))
    (view : ∀ origin, hs.heap.size ∈ γ' origin ↔ c ∈ γ origin)
    (allocated : c < hs.heap.size) :
    LinkClosed (hs.links ++ [(hs.heap.size, c, front)]) γ' := by
  intro v s f member o
  simp only [List.mem_append, List.mem_singleton] at member
  rcases member with oldLink | new
  · exact linkClosed_of_old valid closed old v s f oldLink o
  · obtain ⟨rfl, rfl, rfl⟩ := new
    rw [view o, old o c allocated]

end Ownership.LinkClauses
