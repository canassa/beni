-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.LinkedWriteValidInstance

/-! The dictionary entry witness of #1796. The checker describes a dictionary
as `.list roots value certificate`, with the abstract of the value as the
element. The runtime stores each entry as `.record [.int key, value]`. For a
dictionary of lists, the value's array is at the concrete path
`[.element, .field 1]`, and `namesAt` of the checker's abstract names nothing
there. So no naming covers the final heap of this accepted program
(`no_cover`, kept for the record). The checker accepts the program and both
interpreters give the same trace; the defect was in the relation, not in the
checker.

The owner's decision on #1796 (2026-11-03): read each abstract dictionary
element step as the concrete entry's element step and field 1, in the
coverage and the certificate clauses. The relation reads the abstract through
the value's type (`entryAbstract`, `Soundness.lean`). Through the type, one
naming covers the result path by path (`cover`), the certificates hold
(`certified`), and the full description holds (`described`). The theorems use
definitions only and do not use an unproved statement. -/

namespace Ownership.DictEntryPaths

open InPlaceSemantics HeapProof Soundness

set_option maxRecDepth 100000

def heap : Heap := #[[.int 7], [.record [.int 3, .ref 0]]]

def abstract : Abstract := .list [.site [1, 0] 0] (.list [.site [0] 0] .scalar true) true

/-- The type of the program's result. -/
def ty : Ty := .dict (.list .int)

def program : Program := { main :=
  (.letE 0 (.prim (.literal .int) [.int 7])
    (.letE 1 (.prim (.dictEmpty (.list .int)) [])
      (.letE 2 (.prim .dictInsert [.var 1, .int 3, .var 0])
        (.atom (.var 2))))) }

-- The checker accepts the program, and its result is `abstract`.
#guard match check program with
  | .ok accepted => accepted.result == abstract
  | .error _ => false
-- The result has the type `ty`.
#guard match typecheck program with
  | .ok t => t == ty
  | .error _ => false
-- The in-place run ends with `heap` and returns the dictionary at address 1.
#guard match (InPlaceSemantics.eval 100 [] none [] program.main).run { fuel := 100 } with
  | .ok (.ref 1, state) => state.heap == heap
  | _ => false
-- Both interpreters give the same trace.
#guard match ValueSemantics.run program 100, InPlaceSemantics.run program 100 with
  | .ok a, .ok b => a.reads == b.reads && a.externalReads == b.externalReads &&
      a.finalValue == b.finalValue &&
      a.finalValue == .list [.record [.int 3, .list [.int 7]]]
  | _, _ => false

/-- The old reading: the checker's abstract names nothing at the entry's
    value, so no naming covers the result. -/
theorem no_cover (gamma : Naming) : ¬ Covers gamma heap abstract (.ref 1) := by
  intro cover
  have entryPayload : AtPath heap (.record [.int 3, .ref 0]) [.field 1] (.ref 0) :=
    AtPath.field (xs := [.int 3, .ref 0]) (i := 1) (x := .ref 0) rfl (.here _)
  have atPayload : ArrayAt heap (.ref 1) [.element, .field 1] 0 :=
    AtPath.element (xs := [.record [.int 3, .ref 0]])
      (x := .record [.int 3, .ref 0]) rfl (by simp) entryPayload
  have namedPayload := cover [.element, .field 1] 0 atPayload
  have empty : namesAt abstract [.element, .field 1] = [] := by decide
  rw [empty] at namedPayload
  simp [named] at namedPayload

/-- The abstract through the type: the element is the entry `[key, value]`. -/
theorem typed_abstract :
    entryAbstract [] ty abstract =
      .list [.site [1, 0] 0] (.record [.scalar, .list [.site [0] 0] .scalar true]) true := rfl

/-- The relation maps the abstract element step to the concrete element step
    and field 1. -/
theorem element_path : entryPath ty [.element] = [.element, .field 1] := rfl

theorem element_names :
    namesAt (entryAbstract [] ty abstract) (entryPath ty [.element]) = namesAt abstract [.element] := by
  rfl

/-- The dictionary is array 1, the list in its entry array 0. -/
def naming : Naming
  | .site [1, 0] 0 => [1]
  | .site [0] 0 => [0]
  | _ => []

theorem naming_mem {o : Origin} {c : Nat} (h : c ∈ naming o) :
    (o = .site [1, 0] 0 ∧ c = 1) ∨ (o = .site [0] 0 ∧ c = 0) := by
  unfold naming at h
  split at h
  · simp at h; exact Or.inl ⟨rfl, h⟩
  · simp at h; exact Or.inr ⟨rfl, h⟩
  · simp at h

theorem separating : Separating naming := by
  intro a b hab c hca hcb
  rcases naming_mem hca with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
    rcases naming_mem hcb with ⟨rfl, h⟩ | ⟨rfl, h⟩
  · exact absurd hab (by decide)
  · omega
  · omega
  · exact absurd hab (by decide)

/-- The entry's key holds no array. -/
theorem key_no_array {q : Path} {c : Nat} (h : AtPath heap (.int 3) q (.ref c)) : False := by
  cases h

/-- The values at the paths of the list `[7]` at address 0: itself and its
    integer. -/
theorem list_values {q : Path} {w : Value} (h : AtPath heap (.ref 0) q w) :
    (q = [] ∧ w = .ref 0) ∨ (q = [.element] ∧ w = .int 7) := by
  cases h with
  | here => exact Or.inl ⟨rfl, rfl⟩
  | element lookup member child =>
    change some [Value.int 7] = some _ at lookup
    cases lookup
    simp only [List.mem_singleton] at member
    subst member
    cases child
    exact Or.inr ⟨rfl, rfl⟩

/-- The values at the paths of the entry record: itself, the key, the list
    and its integer. -/
theorem entry_values {q : Path} {w : Value} (h : AtPath heap (.record [.int 3, .ref 0]) q w) :
    (q = [] ∧ w = .record [.int 3, .ref 0]) ∨ (q = [.field 0] ∧ w = .int 3) ∨
      (q = [.field 1] ∧ w = .ref 0) ∨ (q = [.field 1, .element] ∧ w = .int 7) := by
  cases h with
  | here => exact Or.inl ⟨rfl, rfl⟩
  | @field xs i x rest w index child =>
    match i, index with
    | 0, index =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at index
      subst index
      cases child
      exact Or.inr (Or.inl ⟨rfl, rfl⟩)
    | 1, index =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at index
      subst index
      rcases list_values child with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · exact Or.inr (Or.inr (Or.inl ⟨rfl, rfl⟩))
      · exact Or.inr (Or.inr (Or.inr ⟨rfl, rfl⟩))
    | _ + 2, index => simp at index

/-- The values at the paths of the dictionary: itself, the entry, the key,
    the list and its integer. -/
theorem dictionary_values {q : Path} {w : Value} (h : AtPath heap (.ref 1) q w) :
    (q = [] ∧ w = .ref 1) ∨ (q = [.element] ∧ w = .record [.int 3, .ref 0]) ∨
      (q = [.element, .field 0] ∧ w = .int 3) ∨ (q = [.element, .field 1] ∧ w = .ref 0) ∨
      (q = [.element, .field 1, .element] ∧ w = .int 7) := by
  cases h with
  | here => exact Or.inl ⟨rfl, rfl⟩
  | element lookup member child =>
    change some [Value.record [.int 3, .ref 0]] = some _ at lookup
    cases lookup
    simp only [List.mem_singleton] at member
    subst member
    rcases entry_values child with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact Or.inr (Or.inl ⟨rfl, rfl⟩)
    · exact Or.inr (Or.inr (Or.inl ⟨rfl, rfl⟩))
    · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, rfl⟩)))
    · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨rfl, rfl⟩)))

/-- Through the type, one naming covers the result path by path: the
    dictionary at the root, the list at the entry's value. -/
theorem cover : Covers naming heap (entryAbstract [] ty abstract) (.ref 1) := by
  rw [typed_abstract]
  have known : (Origin.unknown == Origin.site [1, 0] 0) = false := rfl
  intro q c located
  rcases dictionary_values located with
    ⟨rfl, same⟩ | ⟨_, same⟩ | ⟨_, same⟩ | ⟨rfl, same⟩ | ⟨_, same⟩
  · cases same
    exact ⟨.site [1, 0] 0, by simp [namesAt, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
  · cases same
  · cases same
  · cases same
    exact ⟨.site [0] 0, by simp [namesAt, Abstract.cellsAt, Abstract.paths, union, known],
      by simp [naming]⟩
  · cases same

/-- The footprint of the list `[7]`. -/
theorem list_footprint {n : Nat} {o : Observation} {fp : List Nat}
    (h : Represents heap n (.ref 0) o fp) : fp = [0] := by
  cases h with
  | ref lookup children =>
    change some [Value.int 7] = some _ at lookup
    cases lookup
    cases children with
    | cons head tail =>
      cases head
      cases tail
      rfl

/-- The footprint of the dictionary: the entries' array, then the list. -/
theorem dictionary_footprint {n : Nat} {o : Observation} {fp : List Nat}
    (h : Represents heap n (.ref 1) o fp) : fp = [1, 0] := by
  cases h with
  | ref lookup children =>
    change some [Value.record [.int 3, .ref 0]] = some _ at lookup
    cases lookup
    cases children with
    | cons head tail =>
      cases tail
      cases head with
      | record fields =>
        cases fields with
        | cons key rest =>
          cases key
          cases rest with
          | cons value none =>
            cases none
            rw [list_footprint value]
            rfl

/-- Through the type, the certificates hold: the dictionary's footprint
    repeats no array, and the list is held once, at its entry's value. -/
theorem certified : CertifiedExclusive heap (entryAbstract [] ty abstract) (.ref 1) := by
  rw [typed_abstract]
  intro q cs e ex w atQ located n o fp represented
  rcases dictionary_values located with
    ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
  · rw [dictionary_footprint represented]
    refine ⟨fun _ => by decide, ?_⟩
    intro _ p c _ child
    rcases dictionary_values child with ⟨h, _⟩ | ⟨_, same⟩ | ⟨_, same⟩ | ⟨_, same⟩ | ⟨_, same⟩
    · cases h
    · cases same
    · cases same
    · cases same
      decide
    · cases same
  · simp [Abstract.atPath] at atQ
  · simp [Abstract.atPath] at atQ
  · rw [list_footprint represented]
    refine ⟨fun _ => by decide, ?_⟩
    intro _ p c _ child
    rcases list_values child with ⟨h, _⟩ | ⟨_, same⟩
    · cases h
    · cases same
  · simp [Abstract.atPath] at atQ

/-- Through the type, the full description holds. -/
theorem described : Describes naming heap (entryAbstract [] ty abstract) (.ref 1) := by
  refine ⟨⟨cover, certified⟩, ?_⟩
  rw [typed_abstract]
  apply ClosureAgreement.array (show heap[1]? = some [.record [.int 3, .ref 0]] from rfl)
  intro x member
  simp only [List.mem_singleton] at member
  subst member
  apply ClosureAgreement.record
  intro i x index
  match i, index with
  | 0, index =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at index
    subst index
    exact .int _ _
  | 1, index =>
    simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at index
    subst index
    apply ClosureAgreement.array (show heap[0]? = some [.int 7] from rfl)
    intro y member
    simp only [List.mem_singleton] at member
    subst member
    exact .int _ _
  | _ + 2, index => simp at index

/-- The witness is in the first flat fragment (slice 3 of #522), so the flat
theorem gives its two runs the same trace through the typed relation. -/
theorem program_flat : Ownership.FlatFragment.Support.FlatANF0 program.main :=
  .letE (.literal .int .int) (.letE (.dictEmpty (.list .int) (.list .int .int))
    (.letE .dictInsert .atom))

theorem program_traces_agree (a : Accepted) (ok : check program = .ok a) (fuel : Nat) (t : Trace)
    (run : ValueSemantics.run program fuel = .ok t) :
    ∃ t', InPlaceSemantics.run program fuel = .ok t' ∧ t.reads = t'.reads ∧
      t.externalReads = t'.externalReads ∧ t.finalValue = t'.finalValue :=
  Ownership.FlatFragment.Preservation.accepted_flat_anf_traces_agree program a ok program_flat fuel t run

end Ownership.DictEntryPaths
