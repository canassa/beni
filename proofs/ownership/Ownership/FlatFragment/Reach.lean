import Ownership.FlatFragment.Atoms

/-! The first flat fragment: footprint membership, the reach frame of a complete footprint, and representation at every covering depth. -/

/-! completeness facts for finite representation footprints.
The induction follows the actual representation depth and the actual list
of represented values. No diagnostic graph or cutoff enters the statements.
-/

namespace Ownership.FlatFragment.FiniteReach

open InPlaceSemantics HeapProof Soundness

theorem representsMany_member {heap : Heap} {depth : Nat} {values : List Value} {observations : List Observation} {footprint : List Nat} {value : Value}
    (represented : RepresentsMany heap depth values observations footprint)
    (member : value ∈ values) :
    ∃ observed cells, Represents heap depth value observed cells ∧
      ∀ address ∈ cells, address ∈ footprint := by
  induction values generalizing observations footprint with
  | nil => simp at member
  | cons head tail ih =>
    cases represented with
    | cons first rest =>
      rcases List.mem_cons.mp member with rfl | later
      · exact ⟨_, _, first, fun address present => List.mem_append.mpr (Or.inl present)⟩
      · obtain ⟨observed, cells, child, subset⟩ := ih rest later
        exact ⟨observed, cells, child,
          fun address present => List.mem_append.mpr (Or.inr (subset address present))⟩

theorem represents_reach_member {heap : Heap} {depth : Nat} {footprint : List Nat} {value : Value} {observation : Observation} {address : Nat}
    (represented : Represents heap depth value observation footprint)
    (reachable : Reaches heap value (.ref address)) : address ∈ footprint := by
  induction depth generalizing value observation footprint with
  | zero => cases represented
  | succ depth ih =>
    cases represented with
    | int => cases reachable
    | record children =>
      cases reachable with
      | field member childReach =>
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact subset address (ih child childReach)
    | closure children =>
      cases reachable with
      | capture member childReach =>
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact subset address (ih child childReach)
    | ref lookup children =>
      cases reachable with
      | refl => simp
      | element actualLookup member childReach =>
        rw [lookup] at actualLookup
        cases actualLookup
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact List.mem_cons_of_mem _ (subset address (ih child childReach))

theorem representsMany_reach_member {heap : Heap} {depth : Nat} {values : List Value} {observations : List Observation} {footprint : List Nat} {value : Value} {address : Nat}
    (represented : RepresentsMany heap depth values observations footprint)
    (member : value ∈ values)
    (reachable : Reaches heap value (.ref address)) : address ∈ footprint := by
  obtain ⟨observed, cells, child, subset⟩ := representsMany_member represented member
  exact subset address (represents_reach_member child reachable)

end Ownership.FlatFragment.FiniteReach

namespace Ownership.FlatFragment.FiniteReachFrame

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.FiniteReach

/-- A complete footprint excludes new reachable values after a disjoint heap change. -/
theorem reaches_before_of_frame
    {before after : Heap} {depth : Nat} {value target : Value}
    {observation : Observation} {footprint : List Nat}
    (represented : Represents before depth value observation footprint)
    (frame : ∀ address ∈ footprint, after[address]? = before[address]?)
    (reachable : Reaches after value target) : Reaches before value target := by
  induction depth generalizing value observation footprint target with
  | zero => cases represented
  | succ depth ih =>
    cases represented with
    | int =>
      cases reachable with
      | refl => exact .refl _
    | record children =>
      cases reachable with
      | refl => exact .refl _
      | field member childReach =>
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact .field member (ih child (fun address present => frame address (subset address present)) childReach)
    | closure children =>
      cases reachable with
      | refl => exact .refl _
      | capture member childReach =>
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact .capture member (ih child (fun address present => frame address (subset address present)) childReach)
    | ref lookup children =>
      cases reachable with
      | refl => exact .refl _
      | element actualLookup member childReach =>
        rw [frame _ (by simp), lookup] at actualLookup
        cases actualLookup
        obtain ⟨observed, cells, child, subset⟩ := representsMany_member children member
        exact .element lookup member (ih child
          (fun address present => frame address (List.mem_cons_of_mem _ (subset address present))) childReach)

end Ownership.FlatFragment.FiniteReachFrame

/-! depth facts for finite representations.
A representation at one depth holds at every depth that covers the
observation's own depth. Correspondence then follows from one complete
finite witness. No theorem uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.RepresentsDepth

open InPlaceSemantics HeapProof Soundness

private theorem max_fold_le (values : List Nat) (initial bound : Nat)
    (fold : values.foldl max initial ≤ bound) :
    initial ≤ bound ∧ ∀ value ∈ values, value ≤ bound := by
  induction values generalizing initial with
  | nil => exact ⟨fold, by simp⟩
  | cons value values ih =>
    obtain ⟨start, rest⟩ := ih (max initial value) fold
    refine ⟨Nat.le_trans (Nat.le_max_left _ _) start, ?_⟩
    intro item member
    rcases List.mem_cons.mp member with rfl | later
    · exact Nat.le_trans (Nat.le_max_right _ _) start
    · exact rest item later

private theorem child_depth_le (children : List Observation) (bound : Nat)
    (fold : (children.attach.map fun child => child.val.depth).foldl max 0 ≤ bound) :
    ∀ child ∈ children, child.depth ≤ bound := by
  intro child member
  obtain ⟨_, elements⟩ := max_fold_le _ _ _ fold
  exact elements child.depth (List.mem_map.mpr ⟨⟨child, member⟩, List.mem_attach _ _, rfl⟩)

theorem container_children_depth (children : List Observation) (depth : Nat)
    (bound : 1 + (children.attach.map fun child => child.val.depth).foldl max 0 ≤ depth + 1) :
    ∀ child ∈ children, child.depth ≤ depth := by
  apply child_depth_le
  omega

mutual
/-- A finite representation stays valid at every depth that covers the
observation. The footprint and the observation stay the same. -/
theorem represents_of_depth (represented : Represents heap depth value observation footprint)
    (enough : observation.depth ≤ target) :
    Represents heap target value observation footprint := by
  cases represented with
  | int =>
    cases target with
    | zero => simp [Observation.depth] at enough
    | succ _ => exact .int
  | record children =>
    cases target with
    | zero => simp [Observation.depth] at enough
    | succ target =>
      have childrenDepth := container_children_depth _ target (by simpa [Observation.depth] using enough)
      exact .record (representsMany_of_depth children childrenDepth)
  | closure children =>
    cases target with
    | zero => simp [Observation.depth] at enough
    | succ target =>
      have childrenDepth := container_children_depth _ target (by simpa [Observation.depth] using enough)
      exact .closure (representsMany_of_depth children childrenDepth)
  | ref lookup children =>
    cases target with
    | zero => simp [Observation.depth] at enough
    | succ target =>
      have childrenDepth := container_children_depth _ target (by simpa [Observation.depth] using enough)
      exact .ref lookup (representsMany_of_depth children childrenDepth)

theorem representsMany_of_depth
    (represented : RepresentsMany heap depth values observations footprint)
    (enough : ∀ observation ∈ observations, observation.depth ≤ target) :
    RepresentsMany heap target values observations footprint := by
  cases represented with
  | nil => exact .nil
  | cons first rest =>
    exact .cons (represents_of_depth first (enough _ (by simp)))
      (representsMany_of_depth rest (fun observation member => enough observation (by simp [member])))
end

/-- One complete finite witness gives correspondence at every sufficient depth. -/
theorem corresponds_of_represents
    (represented : Represents heap depth value observation footprint) :
    Corresponds heap observation value := by
  intro target enough
  exact snapshot_of_represents (represents_of_depth represented enough)

end Ownership.FlatFragment.RepresentsDepth
