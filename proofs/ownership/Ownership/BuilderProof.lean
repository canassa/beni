import Ownership.HeapProof

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
theorem footprint_builder (elements : List Footprint) (outside : Footprint)
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
theorem footprint_close (root : Nat) (elements : List Footprint) (outside : Footprint)
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

open InPlaceSemantics HeapProof

/-- An actual builder allocation has a fresh empty root and frames every
    existing outside holder, even when those holders share with each other. -/
theorem builder_alloc_contract (s : State)
    (outside : RepresentsMany s.heap 256 s.kept.toList observers outsideCells) :
    ∃ s', (prim (.builder t) []).run s = .ok (.ref s.heap.size, s') ∧
      Represents s'.heap 256 (.ref s.heap.size) (.list []) [s.heap.size] ∧
      ExclusiveValue [s.heap.size] outsideCells ∧
      s'.kept = s.kept ∧
      s'.kept.toList.mapM (snapshot s'.heap 256) = .ok observers := by
  refine ⟨{s with heap := s.heap.push []}, rfl, ?_, ?_, rfl, ?_⟩
  · exact .ref (by simp) .nil
  · refine ⟨by simp, ?_⟩
    intro x hx y hy eq
    have hx' : x = s.heap.size := by simpa using hx
    have bound := representsMany_bound outside y hy
    omega
  · exact snapshots_of_represents (representsMany_after_alloc outside)

/-- Exact equation for the executable in-place builder step. -/
theorem put_run (s : State) (h : s.heap[root]? = some xs) :
    (prim .put [.ref root, x]).run s =
      .ok (.ref root, {s with heap := s.heap.set! root (xs ++ [x])}) := by
  have hr : root < s.heap.size := (Array.getElem?_eq_some_iff.mp h).1
  dsimp [prim, array, write, StateT.run, StateT.bind, StateT.get, StateT.set,
    StateT.modifyGet]
  simp only [pure_bind]
  rw [h]
  dsimp [Option.toExcept]
  simp only [pure_bind]
  split <;> rename_i hcond
  · omega
  · rfl

/-- Concrete builder contract: actual `put` preserves the old elements and
    permanent outside readers, appends the value-semantic result, and yields
    exclusive contents. In particular the appended value must itself have no
    repeated reachable cell; a fresh root alone cannot satisfy this premise. -/
theorem builder_put_contract
    (s : State) (lookup : s.heap[root]? = some xs)
    (old : RepresentsMany s.heap n xs os cs)
    (element : Represents s.heap n x o ds)
    (outside : RepresentsMany s.heap 256 s.kept.toList observers outsideCells)
    (oldExclusive : cs.Nodup) (elementExclusive : ds.Nodup)
    (disjoint : Separate cs ds)
    (rootFresh : root ∉ cs ++ ds)
    (unobserved : Separate (root :: (cs ++ ds)) outsideCells) :
    ∃ s', (prim .put [.ref root, x]).run s = .ok (.ref root, s') ∧
      Represents s'.heap (n + 1) (.ref root) (.list (os ++ [o])) (root :: (cs ++ ds)) ∧
      ExclusiveValue (root :: (cs ++ ds)) outsideCells ∧
      s'.kept = s.kept ∧
      s'.kept.toList.mapM (snapshot s'.heap 256) = .ok observers := by
  let s' := {s with heap := s.heap.set! root (xs ++ [x])}
  have hr : root < s.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  have appended : RepresentsMany s.heap n (xs ++ [x]) (os ++ [o]) (cs ++ ds) := by
    simpa using representsMany_append old (RepresentsMany.cons element .nil)
  have contents := representsMany_after_write (xs := xs ++ [x]) appended rootFresh
  have rootOutside : root ∉ outsideCells := by
    intro h
    exact unobserved root (by simp) root h rfl
  refine ⟨s', put_run s lookup, ?_, ?_, rfl, ?_⟩
  · exact .ref (by simp [s', hr]) contents
  · refine ⟨List.nodup_cons.mpr ⟨rootFresh, ?_⟩, unobserved⟩
    exact List.pairwise_append.mpr ⟨oldExclusive, elementExclusive, disjoint⟩
  · exact snapshots_of_represents (representsMany_after_write outside rootOutside)

/-- `close` hands over the same heap representation and certificate; no copy or
    inferred freshness is used to repair a failed builder obligation. -/
theorem close_contract (s : State)
    (representation : Represents s.heap n (.ref root) observation cells)
    (exclusive : ExclusiveValue cells outside) :
    (prim .close [.ref root]).run s = .ok (.ref root, s) ∧
      snapshot s.heap n (.ref root) = .ok observation ∧
      ExclusiveValue cells outside :=
  ⟨rfl, snapshot_of_represents representation, exclusive⟩

theorem close_choice_run (s : State) (built : s.heap[root]? = some xs)
    (source : s.heap[original]? = some ys) :
    (prim .close [.ref root, .ref original]).run s =
      .ok (.ref (if xs == ys then original else root), s) := by
  dsimp [prim, array, StateT.run, StateT.bind, StateT.get]
  simp only [pure_bind]
  rw [built]
  dsimp [Option.toExcept]
  simp only [pure_bind]
  rw [source]
  dsimp [Option.toExcept]
  simp only [pure_bind]
  split <;> rfl

/-- The optional identity shortcut used by ordinary map preserves observations
    and exclusive contents. Full value exclusivity additionally requires the
    chosen root to be fresh with respect to contents and outside holders;
    both possible roots are kept by the checker, not silently called fresh. -/
theorem close_choice_contract (s : State)
    (built : s.heap[root]? = some xs) (source : s.heap[original]? = some ys)
    (contents : RepresentsMany s.heap n xs os cells)
    (unique : cells.Nodup) (separate : Separate cells outside)
    (rootFresh : root ∉ cells) (sourceFresh : original ∉ cells)
    (rootOutside : root ∉ outside) (sourceOutside : original ∉ outside) :
    ∃ chosen, (prim .close [.ref root, .ref original]).run s = .ok (.ref chosen, s) ∧
      Represents s.heap (n + 1) (.ref chosen) (.list os) (chosen :: cells) ∧
      ExclusiveValue (chosen :: cells) outside := by
  have finish (r : Nat) (lookup : s.heap[r]? = some xs)
      (fresh : r ∉ cells) (unobserved : r ∉ outside) :
      Represents s.heap (n + 1) (.ref r) (.list os) (r :: cells) ∧
      ExclusiveValue (r :: cells) outside := by
    refine ⟨.ref lookup contents, List.nodup_cons.mpr ⟨fresh, unique⟩, ?_⟩
    intro c hc d hd eq
    cases List.mem_cons.mp hc with
    | inl heq => exact unobserved ((eq.symm.trans heq) ▸ hd)
    | inr mem => exact separate c mem d hd eq
  by_cases equal : (xs == ys) = true
  · have same := values_beq_sound xs ys equal
    subst ys
    exact ⟨original, by simpa [equal] using close_choice_run s built source,
      finish original source sourceFresh sourceOutside⟩
  · exact ⟨root, by simpa [equal] using close_choice_run s built source,
      finish root built rootFresh rootOutside⟩

/-- This is the actual heap for `[cell, cell]`, not an arbitrary list of ids. -/
def t59Heap : Heap := #[[.int 0], [.ref 0, .ref 0]]

theorem t59_concrete_sharing :
    Represents t59Heap 3 (.ref 1) (.list [.list [.int 0], .list [.int 0]]) [1, 0, 0] := by
  apply Represents.ref rfl
  exact RepresentsMany.cons (cs := [0]) (ds := [0])
    (.ref (vs := [.int 0]) rfl (.cons .int .nil))
    (.cons (.ref (vs := [.int 0]) rfl (.cons .int .nil)) .nil)

theorem t59_not_exclusive (outside : Footprint) :
    ¬ ExclusiveValue [1, 0, 0] outside := by
  intro h
  have repeated : ¬ ([1, 0, 0] : Footprint).Nodup := by decide
  exact repeated h.1

end Ownership.BuilderProof
