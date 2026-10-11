import Std

namespace Ownership.BuilderProof

/-- A footprint lists one cell for each concrete tracked path, with multiplicity.
    It includes nested list cells and cells in closure environments. Removing
    duplicates here would erase precisely the premise T59 needs. -/
abbrev Footprint := List Nat

def Separate (a b : Footprint) : Prop :=
  ∀ x ∈ a, ∀ y ∈ b, x ≠ y

/-- The concrete form of the thesis's three exclusive-contents conditions:
    no repeated path to a cell, including within one element, and no outside
    live holder. The list's own root is supplied separately by `close`. -/
def ExclusiveContents (elements : List Footprint) (outside : Footprint) : Prop :=
  elements.flatten.Nodup ∧ Separate elements.flatten outside

def ExclusiveValue (value outside : Footprint) : Prop :=
  value.Nodup ∧ Separate value outside

/-- Proof (a), builder: internal exclusivity AND separation between results.
    Merely allocating each result afresh does not establish `internal`. -/
theorem builder_contract (elements : List Footprint) (outside : Footprint)
    (internal : ∀ e ∈ elements, e.Nodup)
    (between : elements.Pairwise Separate)
    (unobserved : ∀ e ∈ elements, Separate e outside) :
    ExclusiveContents elements outside := by
  constructor
  · exact List.pairwise_flatten.mpr ⟨internal, between⟩
  · intro x hx y hy
    obtain ⟨e, he, hxe⟩ := List.mem_flatten.mp hx
    exact unobserved e he x hxe y hy

/-- Closing a builder adds its unaliased root. No copy repairs a failed premise. -/
theorem close_contract (root : Nat) (elements : List Footprint) (outside : Footprint)
    (contents : ExclusiveContents elements outside)
    (rootFresh : root ∉ elements.flatten)
    (rootUnobserved : root ∉ outside) :
    ExclusiveValue (root :: elements.flatten) outside := by
  constructor
  · exact List.nodup_cons.mpr ⟨rootFresh, contents.1⟩
  · intro x hx y hy
    cases List.mem_cons.mp hx with
    | inl h =>
      subst x
      intro eq
      exact rootUnobserved (eq ▸ hy)
    | inr h => exact contents.2 x h y hy

/-- The smallest T59 footprint has a fresh outer root but two paths to cell 1. -/
theorem t59_missing_premise : ¬ ([0, 1, 1] : Footprint).Nodup := by
  decide

end Ownership.BuilderProof
