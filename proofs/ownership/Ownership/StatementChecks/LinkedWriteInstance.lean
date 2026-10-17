-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.CallDerivationInstance

/-! The naming clause through a real linked write, from the review of PR #285
(note 2). Every hypothesis of `LinkedWriteStep.linkNamed_after_writeLinked_liveCells`
holds at a reachable state with two link components: the accepted program
`xs = [1, 2]; rest = view xs; ys = [3, 4]; tl = view ys; push rest 9;
length tl + length ys`, just before the push. The push writes the first
component (its source `xs` is dead); the second component stays live, so the
lemma's conclusion constrains it after the write. The pre-state `Invariant`
is a kernel proof; the demand and the linked write are the real ones.
`second_constrained` shows that the conclusion is not vacuous. -/

namespace Ownership.LinkedWriteInstance

open InPlaceSemantics HeapProof Soundness LinkedWriteFrame
open Ownership.FlatFragment.Description

set_option maxRecDepth 100000

def fuel : Nat := ({} : Config).inferenceFuel
def lit (a b : Int) : Expr := .prim (.literal .int) [.int a, .int b]

def pairPrefix (k : Expr) : Expr :=
  .letE 0 (lit 1 2) (.letE 1 (.prim (.view true) [.var 0])
    (.letE 2 (lit 3 4) (.letE 3 (.prim (.view true) [.var 2]) k)))
def pairRest : Expr :=
  .letE 5 (.prim .length [.var 3]) (.letE 6 (.prim .length [.var 2]) (.prim .add [.var 5, .var 6]))
def pairProgram : Program := { main := pairPrefix (.letE 4 (.prim .push [.var 1, .int 9]) pairRest) }

def s0 : Origin := .site [0] 0
def s1 : Origin := .site [1, 0] 0
def s2 : Origin := .site [1, 1, 0] 0
def s3 : Origin := .site [1, 1, 1, 0] 0
def xsAbs : Abstract := .list [s0] .scalar ⟨true, true⟩
def restAbs : Abstract := .list [s0, s1] .scalar ⟨true, true⟩
def ysAbs : Abstract := .list [s2] .scalar ⟨true, true⟩
def tlAbs : Abstract := .list [s2, s3] .scalar ⟨true, true⟩

def naming : Naming
  | .site [0] 0 => [0, 1]
  | .site [1, 1, 0] 0 => [2, 3]
  | _ => []

theorem naming_mem {o : Origin} {c : Nat} (h : c ∈ naming o) :
    (o = s0 ∧ (c = 0 ∨ c = 1)) ∨ (o = s2 ∧ (c = 2 ∨ c = 3)) := by
  unfold naming at h
  split at h
  · simp at h; exact Or.inl ⟨rfl, h⟩
  · simp at h; exact Or.inr ⟨rfl, h⟩
  · simp at h

theorem separating : Separating naming := by
  intro a b hab c ha hb
  rcases naming_mem ha with ⟨rfl, hc⟩ | ⟨rfl, hc⟩ <;>
    rcases naming_mem hb with ⟨rfl, hc'⟩ | ⟨rfl, hc'⟩
  · exact absurd hab (by decide)
  · omega
  · omega
  · exact absurd hab (by decide)

theorem naming_s0 : naming s0 = [0, 1] := rfl
theorem naming_s2 : naming s2 = [2, 3] := rfl

theorem namedTwo (a b : Origin) (c : Nat) (h : c ∈ naming a) :
    named naming ((Abstract.list [a, b] .scalar ⟨true, true⟩).cellsAt []) c := by
  have root := FlatFragment.Description.named_list_root (gamma := naming) (roots := [a, b])
    (element := .scalar) (certificate := ⟨true, true⟩) (root := c) ⟨a, by simp, h⟩
  simpa [namesAt] using root

theorem namedOne (a : Origin) (c : Nat) (h : c ∈ naming a) :
    named naming ((Abstract.list [a] .scalar ⟨true, true⟩).cellsAt []) c := by
  have root := FlatFragment.Description.named_list_root (gamma := naming) (roots := [a])
    (element := .scalar) (certificate := ⟨true, true⟩) (root := c) ⟨a, by simp, h⟩
  simpa [namesAt] using root

def hs : State :=
  { fuel := 990, heap := #[[.int 1, .int 2], [.int 2], [.int 3, .int 4], [.int 4]],
    links := [(1, 0, true), (3, 2, true)] }
def vs : ValueSemantics.State := { fuel := 990 }
def env : List (Var × Observation × Value) :=
  [(3, .list [.int 4], .ref 3), (2, .list [.int 3, .int 4], .ref 2),
   (1, .list [.int 2], .ref 1), (0, .list [.int 1, .int 2], .ref 0)]
def aenv : Env Abstract := [(3, tlAbs), (2, ysAbs), (1, restAbs), (0, xsAbs)]
def after : Live := removeVars [4] (union (uses pairRest) [])
def live : Live := union (uses (.prim .push [.var 1, .int 9])) after

#guard (check pairProgram).isOk
#guard match ValueSemantics.run pairProgram 1000, InPlaceSemantics.run pairProgram 1000 with
  | .ok t, .ok t' => t.finalValue == .int 3 && t'.finalValue == t.finalValue
  | _, _ => false

theorem reached :
    (InPlaceSemantics.eval 1000 [] none [] (pairPrefix (.atom (.int 0)))).run { fuel := 1000 } =
      .ok (.int 0, { hs with fuel := 991 }) := by cbv

theorem checker_env :
    ((inferExpr fuel { declarations := [], config := {} } []
      (pairPrefix (.prim .record [.var 3, .var 2, .var 1, .var 0])) [] []).run {}).map (·.1) =
      .ok (.record [tlAbs, ysAbs, restAbs, xsAbs]) := by cbv

theorem after_eq : after = [(3, []), (2, [])] := by cbv
theorem live_eq : live = [(1, []), (3, []), (2, [])] := by cbv

theorem invariant : Invariant vs hs env live aenv ({} : St).facts.escapes naming := by
  refine
    { reads := rfl, external := rfl, fuel := rfl, keptSize := rfl
      kept := ?_, keptEscaped := ?_, bindings := ?_, described := ?_, named := ?_
      separating := separating, linksValid := ?_, linkNamed := ?_ }
  · intro i o w h
    simp [vs] at h
  · intro k hk
    simp [hs] at hk
  · intro x p hl o w he
    rw [live_eq] at hl
    simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hl
    rcases hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
      cases he
      refine ⟨_, _, rfl, rfl, ?_⟩
      intro n hn
      rcases n with _ | _ | n
      · simp [Observation.depth] at hn
      · simp [Observation.depth] at hn
      · rfl
    · change some (Observation.list [.int 4], Value.ref 3) = some (o, w) at he
      cases he
      refine ⟨_, _, rfl, rfl, ?_⟩
      intro n hn
      rcases n with _ | _ | n
      · simp [Observation.depth] at hn
      · simp [Observation.depth] at hn
      · rfl
    · change some (Observation.list [.int 3, .int 4], Value.ref 2) = some (o, w) at he
      cases he
      refine ⟨_, _, rfl, rfl, ?_⟩
      intro n hn
      rcases n with _ | _ | n
      · simp [Observation.depth] at hn
      · simp [Observation.depth] at hn
      · rfl
  · intro x p hl o w a w' he ha hp
    rw [live_eq] at hl
    simp only [List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at hl
    rcases hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
      cases he
      change some restAbs = some a at ha
      cases ha
      change some (Value.ref 1) = some w' at hp
      cases hp
      exact allocated_list_described (integers := [2]) rfl ⟨s0, by simp, by simp [naming_s0]⟩
    · change some (Observation.list [.int 4], Value.ref 3) = some (o, w) at he
      cases he
      change some tlAbs = some a at ha
      cases ha
      change some (Value.ref 3) = some w' at hp
      cases hp
      exact allocated_list_described (integers := [4]) rfl ⟨s2, by simp, by simp [naming_s2]⟩
    · change some (Observation.list [.int 3, .int 4], Value.ref 2) = some (o, w) at he
      cases he
      change some ysAbs = some a at ha
      cases ha
      change some (Value.ref 2) = some w' at hp
      cases hp
      exact allocated_list_described (integers := [3, 4]) rfl ⟨s2, by simp, by simp [naming_s2]⟩
  · intro x o w a he ha q c hq hac
    rcases x with _ | _ | _ | _ | x
    · change some (Observation.list [.int 1, .int 2], Value.ref 0) = some (o, w) at he
      cases he
      change some xsAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [1, 2]) rfl hac
      exact namedOne s0 0 (by simp [naming_s0])
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
      cases he
      change some restAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [2]) rfl hac
      exact namedTwo s0 s1 1 (by simp [naming_s0])
    · change some (Observation.list [.int 3, .int 4], Value.ref 2) = some (o, w) at he
      cases he
      change some ysAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [3, 4]) rfl hac
      exact namedOne s2 2 (by simp [naming_s2])
    · change some (Observation.list [.int 4], Value.ref 3) = some (o, w) at he
      cases he
      change some tlAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [4]) rfl hac
      exact namedTwo s2 s3 3 (by simp [naming_s2])
    · simp [env, List.lookup] at he
  · refine ⟨?_, ?_, ?_, ?_⟩
    · intro v s f member
      simp only [hs, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
      rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ <;> decide
    · intro v s f member
      simp only [hs, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
      rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩
      · exact ⟨[.int 1, .int 2], rfl, by simp⟩
      · exact ⟨[.int 3, .int 4], rfl, by simp⟩
    · decide
    · intro v s f member
      simp only [hs, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
      rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩
      · exact ⟨[.int 1, .int 2], rfl, rfl⟩
      · exact ⟨[.int 3, .int 4], rfl, rfl⟩
  · apply LinkClauses.linkNamed_of_closed
    intro v s f member o
    simp only [hs, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
    rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ <;>
    · unfold naming
      split <;> simp

/-- The real default demand of the push: the receiver's root cells against
    the continuation's live cells, with no other operand cells. -/
theorem demand_run : ∃ (u : Unit) (st : St),
    (demand ({} : Config) [s0, s1] (liveCells aenv after) []).run ({} : St) = .ok (u, st) := by
  cases h : (demand ({} : Config) [s0, s1] (liveCells aenv after) []).run ({} : St) with
  | ok v => exact ⟨v.1, v.2, rfl⟩
  | error e =>
    have ok : ((demand ({} : Config) [s0, s1] (liveCells aenv after) []).run ({} : St)).isOk = true := by cbv
    rw [h] at ok
    cases ok

/-- The real linked write of the push: `rest` becomes `[2, 9]`, and the
    splice writes its source `xs` to `[1, 2, 9]`. -/
def hsAfter : State :=
  { hs with heap := #[[.int 1, .int 2, .int 9], [.int 2, .int 9], [.int 3, .int 4], [.int 4]] }

theorem write_run : (writeLinked 1 [.int 2, .int 9]).run hs = .ok (.ref 1, hsAfter) := by cbv

theorem after_named : LinkNamed hsAfter env after naming := by
  obtain ⟨u, st, demandRun⟩ := demand_run
  exact LinkedWriteStep.linkNamed_after_writeLinked_liveCells (x := 1) (c := 1) invariant
    (by
      intro u hu
      rw [after_eq] at hu
      rw [live_eq]
      simp at hu ⊢
      rcases hu with rfl | rfl <;> simp)
    (by rw [live_eq]; simp) rfl ⟨s0, by simp, by simp [naming_s0]⟩
    demandRun (fun cell hc => hc)
    (by
      intro y p hy o w he
      rw [after_eq] at hy
      simp at hy
      rcases hy with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> rfl)
    write_run

/-- The conclusion is not vacuous: after the write, the live `ys` protects
    the second component, so `LinkNamed` names arrays 2 and 3 alike there. -/
theorem second_protected : Protected hsAfter env after 2 :=
  Or.inl ⟨2, [], .list [.int 3, .int 4], .ref 2, .ref 2, by rw [after_eq]; simp, rfl, rfl, Reaches.refl _⟩

theorem second_constrained : ∀ o, 3 ∈ naming o ↔ 2 ∈ naming o :=
  after_named 3 2 (LinkConnected.edge (front := true) (by simp [hsAfter, hs])) second_protected

/-- The linked write changed the dead source `xs` as well as `rest`. -/
theorem source_changed : hsAfter.heap[0]? ≠ hs.heap[0]? := by
  intro h
  simp [hsAfter, hs] at h


end Ownership.LinkedWriteInstance
