-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.SummaryObservers

/-! A content-consistent suffix link defeats address-only separation.
The current step premises permit the pre-state, but no post-invariant exists (#169).
These proofs use definitions and do not use the unproved step theorem. -/

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

theorem invariant :
    Invariant valuePre heapPre pairedEnv (union (uses expression) after) abstractEnv [] naming := by
  refine
    { reads := rfl, external := rfl, fuel := rfl, keptSize := rfl
      kept := ?_, keptEscaped := ?_, bindings := ?_, described := ?_, named := ?_
      separating := separating }
  · intro i o w ho
    simp [valuePre] at ho
  · intro k hk
    simp [heapPre] at hk
  · intro x p hl o w he
    rcases live_cases x p hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (.list [], .ref 0) = some (o, w) at he
      cases he
      exact ⟨.list [], .ref 0, rfl, rfl, corresponds_empty⟩
    · change some (.list [.int 0], .ref 1) = some (o, w) at he
      cases he
      exact ⟨.list [.int 0], .ref 1, rfl, rfl, corresponds_source⟩
  · intro x p hl o w a w' he ha hp
    rcases live_cases x p hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (.list [], .ref 0) = some (o, w) at he
      cases he
      change some (abstractValue 0) = some a at ha
      cases ha
      change some (.ref 0) = some w' at hp
      cases hp
      exact described_empty
    · change some (.list [.int 0], .ref 1) = some (o, w) at he
      cases he
      change some (abstractValue 1) = some a at ha
      cases ha
      change some (.ref 1) = some w' at hp
      cases hp
      exact described_source
  · intro x o w a he ha q c hq hc
    cases x with
    | zero =>
      change some (.list [], .ref 0) = some (o, w) at he
      cases he
      change some (abstractValue 0) = some a at ha
      cases ha
      cases hc with
      | here =>
        exact ⟨.site [] 0, by simp [abstractValue, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
      | element => simp [immutablePath] at hq
    | succ x =>
      cases x with
      | zero =>
        change some (.list [.int 0], .ref 1) = some (o, w) at he
        cases he
        change some (abstractValue 1) = some a at ha
        cases ha
        cases hc with
        | here =>
          exact ⟨.site [] 1, by simp [abstractValue, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
        | element => simp [immutablePath] at hq
      | succ x =>
        change none = some (o, w) at he
        contradiction

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

end Ownership.ViewCounterexample
