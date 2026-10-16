-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.SummaryObservers

/-! A content-consistent suffix link defeats address-only separation (#169).
Before the link clauses, the step premises admitted this pre-state, and no
post-invariant existed (`no_post_invariant`, kept for the record). With the
clauses, no naming satisfies the invariant on the pre-state (`no_invariant`):
the live source protects the link component, so the view must carry the
source's origins, and the two distinct sites do not alias. These proofs use
definitions and do not use the unproved step theorem.

*A stale garbage view.* A builder's `put` writes with `write`, not
`writeLinked`. A builder closed into a list, viewed, and grown again with
`put` leaves its view stale: the checker accepts the program (nothing live
holds the view or the list), both runs print `[1, 2]`, and the final heap
holds the view as `[]` where its source's suffix is `[2]`. So a view's
contents are not a clause of the invariant; a protected view is never stale,
because its cells include its source's and the demand on the source fails. -/

namespace Ownership.ViewCounterexample

open InPlaceSemantics HeapProof Soundness

set_option maxRecDepth 100000

def program : Program := { main := .atom (.int 0) }
def accepted : Accepted :=
  match check program with
  | .ok a => a
  | .error _ => default

def expression : Expr := .prim .push [.var 0, .int 1]
def after : Live := [(1, [])]
def abstractValue (i : Nat) : Abstract := .list [.site [] i] .scalar false
def abstractEnv : Env Abstract := [(0, abstractValue 0), (1, abstractValue 1)]
def pairedEnv : List (Var × Observation × Value) :=
  [(0, .list [], .ref 0), (1, .list [.int 0], .ref 1)]
def typeEnv : Env Ty := [(0, .list .int), (1, .list .int)]

def valuePre : ValueSemantics.State := { fuel := 10 }
def heapPre : State :=
  { fuel := 10, heap := #[[], [.int 0]], links := [(0, 1, true)] }
def valuePost : ValueSemantics.State := { fuel := 9 }
def heapPost : State :=
  { heapPre with fuel := 9, heap := #[[.int 1], [.int 0, .int 1]], writes := 1 }

def naming (o : Origin) : List Nat :=
  match o with
  | .site [] i => [i]
  | _ => []

#guard (check program).isOk
#guard ((inferExpr 200 { declarations := [], config := {} } abstractEnv expression after []).run {}).isOk
#guard heapPre.heap[0]? == some (viewOf true [.int 0])
#guard match (ValueSemantics.eval 10 [] none (valueEnv pairedEnv) expression).run valuePre with
  | .ok (r, s) => r == .list [.int 1] && s.fuel == 9
  | .error _ => false
#guard match (InPlaceSemantics.eval 10 [] none (heapEnv pairedEnv) expression).run heapPre with
  | .ok (r, s) => r == .ref 0 && s.heap == heapPost.heap && s.fuel == 9
  | .error _ => false
#guard match snapshot heapPost.heap 2 (.ref 1) with
  | .ok o => o == .list [.int 0, .int 1]
  | .error _ => false

theorem accepted_ok : check program = .ok accepted := by cbv

theorem accepted_expression :
    (inferExpr ({} : Config).inferenceFuel { declarations := [], config := {} }
      abstractEnv expression after []).run {} = .ok (abstractValue 0, {}) := by cbv

theorem main_context :
    MainContext program accepted { declarations := [], config := {} } {} :=
  ⟨rfl, corrected_default, by simp⟩

theorem separating : Separating naming := by
  intro a b hab c hca hcb
  cases a <;> try simp [naming] at hca
  case site s i =>
    cases s with
    | cons n s => simp [naming] at hca
    | nil =>
      simp only [naming, List.mem_singleton] at hca
      subst c
      cases b <;> try simp [naming] at hcb
      case site t j =>
        cases t with
        | cons n t => simp [naming] at hcb
        | nil =>
          simp only [naming, List.mem_singleton] at hcb
          subst j
          change (true && (i == i)) = false at hab
          simp at hab

theorem corresponds_empty : Corresponds heapPre.heap (.list []) (.ref 0) := by
  intro n hn
  cases n with
  | zero => simp [Observation.depth] at hn
  | succ n => rfl

theorem corresponds_source : Corresponds heapPre.heap (.list [.int 0]) (.ref 1) := by
  intro n hn
  cases n with
  | zero => simp [Observation.depth] at hn
  | succ n =>
    cases n with
    | zero => simp [Observation.depth] at hn
    | succ n => rfl

theorem described_empty : Describes naming heapPre.heap (abstractValue 0) (.ref 0) := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c h
    obtain ⟨hq, hw⟩ := atPath_empty_ref (show heapPre.heap[0]? = some [] from rfl) h
    subst hq
    cases hw
    exact ⟨.site [] 0, by simp [namesAt, abstractValue, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
  · intro q cs e ex w ha hp n o fp hr
    obtain ⟨hq, hw⟩ := atPath_empty_ref (show heapPre.heap[0]? = some [] from rfl) hp
    subst hq
    change abstractValue 0 = .list cs e ex at ha
    cases ha
    simp [abstractValue] at *
  · apply ClosureAgreement.array (show heapPre.heap[0]? = some [] from rfl)
    intro x hx
    simp at hx

theorem described_source : Describes naming heapPre.heap (abstractValue 1) (.ref 1) := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c h
    cases h with
    | here =>
      exact ⟨.site [] 1, by simp [namesAt, abstractValue, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
    | element lookup mem child =>
      change some ([.int 0] : List Value) = some _ at lookup
      cases lookup
      simp only [List.mem_singleton] at mem
      subst mem
      cases child
  · intro q cs e ex w ha hp n o fp hr
    cases hp with
    | here =>
      change abstractValue 1 = .list cs e ex at ha
      cases ha
      simp [abstractValue] at *
    | element lookup mem child =>
      change some ([.int 0] : List Value) = some _ at lookup
      cases lookup
      simp only [List.mem_singleton] at mem
      subst mem
      cases child with
      | here => simp [abstractValue, Abstract.atPath] at ha
  · apply ClosureAgreement.array (show heapPre.heap[1]? = some [.int 0] from rfl)
    intro x hx
    simp only [List.mem_singleton] at hx
    subst x
    exact .int _ _

theorem live_cases (x : Var) (p : Path)
    (h : (x, p) ∈ union (uses expression) after) :
    (x = 0 ∧ p = []) ∨ (x = 1 ∧ p = []) := by
  have liveEq : union (uses expression) after = [(0, []), (1, [])] := by cbv
  rw [liveEq] at h
  simpa using h

/-- The strengthened invariant admits no naming for this pre-state: the
    live source protects the link component, so the view must carry the
    source's origins; each is named by its own site, and the two sites do
    not alias. -/
theorem no_invariant (gamma : Naming) :
    ¬ Invariant valuePre heapPre pairedEnv (union (uses expression) after) abstractEnv [] gamma := by
  intro h
  have liveEq : union (uses expression) after = [(0, []), (1, [])] := by cbv
  have yLive : (1, []) ∈ union (uses expression) after := by rw [liveEq]; simp
  obtain ⟨xOrigin, xMember, xIn⟩ :=
    h.named 0 (.list []) (.ref 0) (abstractValue 0) rfl rfl [] 0 rfl (AtPath.here _)
  obtain ⟨yOrigin, yMember, yIn⟩ :=
    h.named 1 (.list [.int 0]) (.ref 1) (abstractValue 1) rfl rfl [] 1 rfl (AtPath.here _)
  simp [abstractValue, Abstract.cellsAt, Abstract.paths, union] at xMember yMember
  subst xMember
  subst yMember
  have connected : LinkedWriteFrame.LinkConnected heapPre.links 0 1 :=
    LinkedWriteFrame.LinkConnected.edge (front := true) (by simp [heapPre])
  have sourceProtected : Protected heapPre pairedEnv (union (uses expression) after) 1 :=
    Or.inl ⟨1, [], .list [.int 0], .ref 1, .ref 1, yLive, rfl, rfl, Reaches.refl _⟩
  have sourceNamed : 1 ∈ gamma (.site [] 0) :=
    (h.linkNamed 0 1 connected sourceProtected (.site [] 0)).mp xIn
  have distinct : aliases (.site [] 0) (.site [] 1) = false := by decide
  exact h.separating (.site [] 0) (.site [] 1) distinct 1 sourceNamed yIn

theorem typed : WellTyped [] heapPre.heap pairedEnv expression := by
  refine ⟨typeEnv, .list .int, by cbv, ?_⟩
  intro x o w u he ht
  cases x with
  | zero =>
    change some (.list [], .ref 0) = some (o, w) at he
    cases he
    change some (.list .int) = some u at ht
    cases ht
    exact ⟨by decide +kernel, ⟨1, .list [], [0], .ref rfl .nil, by decide +kernel⟩⟩
  | succ x =>
    cases x with
    | zero =>
      change some (.list [.int 0], .ref 1) = some (o, w) at he
      cases he
      change some (.list .int) = some u at ht
      cases ht
      exact ⟨by decide +kernel,
        ⟨2, .list [.int 0], [1], .ref rfl (.cons .int .nil), by decide +kernel⟩⟩
    | succ x =>
      change none = some (o, w) at he
      contradiction

theorem honest : ∀ x a, abstractEnv.lookup x = some a → HonestClosures [] a := by
  intro x a ha
  cases x with
  | zero =>
    change some (abstractValue 0) = some a at ha
    cases ha
    intro roots alts hc
    cases hc with
    | list child => cases child
  | succ x =>
    cases x with
    | zero =>
      change some (abstractValue 1) = some a at ha
      cases ha
      intro roots alts hc
      cases hc with
      | list child => cases child
    | succ x =>
      change none = some a at ha
      contradiction

theorem covered : ∀ x q, (x, q) ∈ union (uses expression) after →
    ∀ o w, pairedEnv.lookup x = some (o, w) → (abstractEnv.lookup x).isSome = true := by
  intro x q hl o w he
  rcases live_cases x q hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> rfl

theorem value_run :
    (ValueSemantics.eval 10 [] none (valueEnv pairedEnv) expression).run valuePre =
      .ok (.list [.int 1], valuePost) := by cbv

theorem heap_run :
    (InPlaceSemantics.eval 10 [] none (heapEnv pairedEnv) expression).run heapPre =
      .ok (.ref 0, heapPost) := by cbv

theorem no_post_invariant (gamma : Naming) :
    ¬ Invariant valuePost heapPost pairedEnv after abstractEnv [] gamma := by
  intro h
  obtain ⟨o, w, ho, hw, hc⟩ := h.bindings 1 [] (by simp [after])
    (.list [.int 0]) (.ref 1) rfl
  change some (.list [.int 0]) = some o at ho
  cases ho
  change some (.ref 1) = some w at hw
  cases hw
  have impossible := hc 2 (by decide +kernel)
  have snap : snapshot heapPost.heap 2 (.ref 1) = .ok (.list [.int 0, .int 1]) := by cbv
  rw [snap] at impossible
  cases impossible

/-! ## A stale garbage view (`put` writes with `write`) -/

def staleMain : Expr :=
  .letE 0 (.prim (.builder .int) [])
  (.letE 1 (.prim .put [.var 0, .int 1])
  (.letE 2 (.prim .close [.var 1])
  (.letE 3 (.prim (.view true) [.var 2])
  (.letE 4 (.prim .put [.var 1, .int 2])
  (.prim .close [.var 4])))))

def staleProgram : Program := { main := staleMain }

#guard (check staleProgram).isOk
#guard match ValueSemantics.run staleProgram, InPlaceSemantics.run staleProgram with
  | .ok t, .ok t' => t.finalValue == .list [.int 1, .int 2] && t'.finalValue == t.finalValue
  | _, _ => false
#guard match (InPlaceSemantics.eval 1000 [] none [] staleMain).run { fuel := 1000 } with
  | .ok (_, s) => s.links == [(1, 0, true)] && s.heap[1]? == some [] &&
      s.heap[0]? == some [.int 1, .int 2] && viewOf true [.int 1, .int 2] == [.int 2]
  | .error _ => false

end Ownership.ViewCounterexample
