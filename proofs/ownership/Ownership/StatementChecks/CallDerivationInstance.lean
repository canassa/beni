-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.LinkedCallControl

/-! The derivation of the written-storage premise at a real call, from the
review of PR #276 (note 2). Every hypothesis of
`CallDerivation.linkedWritesCovered_of_applyCall` holds at a reachable
first-order call with a link: `w(rest)` in the accepted
program `xs = [1, 2]; rest = view xs; f = w; f(rest)`, with `xs` dead after
the call. The call-site `Invariant` is a kernel proof; the call's
`applyCall` run is the real checker's (by `cbv`). The theorem then gives
`LinkedWritesCovered` for the real published summary at the caller's state,
the same conclusion `LinkedCallControl.linked` proves directly. The program is
`LinkedCallControl.program`. -/

namespace Ownership.CallDerivationInstance

open InPlaceSemantics HeapProof Soundness LinkedWriteFrame
open Ownership.FlatFragment.Description

set_option maxRecDepth 100000

def fuel : Nat := ({} : Config).inferenceFuel
def lit : Expr := .prim (.literal .int) [.int 1, .int 2]

def writer : Decl := LinkedCallControl.writer
def callPrefix (k : Expr) : Expr :=
  .letE 0 lit (.letE 1 (.prim (.view true) [.var 0]) (.letE 2 (.closure 0 []) k))
def call : Expr := .app (.var 2) [.var 1]
def callRest : Expr := .letE 3 call (.prim .length [.var 3])
def program : Program := LinkedCallControl.program

theorem program_eq : program = { declarations := [writer], main := callPrefix callRest } := rfl

def entry : CacheEntry := LinkedCallControl.entry

def s0 : Origin := .site [0] 0
def s1 : Origin := .site [1, 0] 0
def xsAbs : Abstract := .list [s0] .scalar ⟨true, true⟩
def restAbs : Abstract := .list [s0, s1] .scalar ⟨true, true⟩
def fAbs : Abstract := .function [] [(0, [])]

def naming : Naming
  | .site [0] 0 => [0, 1]
  | _ => []

theorem naming_mem {o : Origin} {c : Nat} (h : c ∈ naming o) : o = s0 := by
  unfold naming at h
  split at h
  · rfl
  · simp at h

theorem separating : Separating naming := by
  intro a b hab c ha hb
  have ea := naming_mem ha
  have eb := naming_mem hb
  subst ea
  subst eb
  exact absurd hab (by decide)

theorem naming_s0 : naming s0 = [0, 1] := rfl

theorem restNamed (c : Nat) (h : c ∈ naming s0) : named naming (restAbs.cellsAt []) c := by
  have root := FlatFragment.Description.named_list_root (gamma := naming) (roots := [s0, s1])
    (element := .scalar) (certificate := ⟨true, true⟩) (root := c) ⟨s0, by simp, h⟩
  simpa [namesAt] using root

theorem bottom_shallow (heap : Heap) : DescribesShallow naming heap .bottom (.int 0) := by
  refine ⟨?_, ?_⟩
  · intro q c h
    cases h
  · intro q cs e ex w ha hp n o fp hr
    cases hp
    simp [Abstract.atPath] at ha

theorem describes_f (heap : Heap) : Describes naming heap fAbs (.closure 0 []) := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c h
    cases h with
    | capture l _ => simp at l
    | env m _ => simp at m
  · intro q cs e ex w ha hp n o fp hr
    cases hp with
    | here => simp [fAbs, Abstract.atPath] at ha
    | capture l _ => simp at l
    | env m _ => simp at m
  · refine ClosureAgreement.known (abs := []) (by simp) rfl ?_ ?_
    · intro k
      simpa using bottom_shallow heap
    · intro k
      simpa using ClosureAgreement.int (γ := naming) (heap := heap) .bottom 0

def hs : State := { fuel := 994, heap := #[[.int 1, .int 2], [.int 2]], links := [(1, 0, true)] }
def vs : ValueSemantics.State := { fuel := 994 }
def env : List (Var × Observation × Value) :=
  [(2, .closure 0 [], .closure 0 []), (1, .list [.int 2], .ref 1), (0, .list [.int 1, .int 2], .ref 0)]
def aenv : Env Abstract := [(2, fAbs), (1, restAbs), (0, xsAbs)]
/-- The uses of the call and of its continuation: `xs` is dead. -/
def live : Live := union (uses call) (removeVars [3] (union (uses (.prim .length [.var 3])) []))

theorem reached :
    (InPlaceSemantics.eval 1000 [writer] none [] (callPrefix (.atom (.int 0)))).run { fuel := 1000 } =
      .ok (.int 0, { hs with fuel := 993 }) := by cbv

theorem checker_env :
    ((inferExpr fuel { declarations := [writer], config := {} } []
      (callPrefix (.prim .record [.var 2, .var 1, .var 0])) [] []).run {}).map (·.1) =
      .ok (.record [fAbs, restAbs, xsAbs]) := by cbv

theorem live_eq : live = [(2, []), (1, [])] := by cbv

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
    rcases hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (Observation.closure 0 [], Value.closure 0 []) = some (o, w) at he
      cases he
      refine ⟨_, _, rfl, rfl, ?_⟩
      intro n hn
      rcases n with _ | n
      · simp [Observation.depth] at hn
      · rfl
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
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
    rcases hl with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change some (Observation.closure 0 [], Value.closure 0 []) = some (o, w) at he
      cases he
      change some fAbs = some a at ha
      cases ha
      change some (Value.closure 0 []) = some w' at hp
      cases hp
      exact describes_f _
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
      cases he
      change some restAbs = some a at ha
      cases ha
      change some (Value.ref 1) = some w' at hp
      cases hp
      exact allocated_list_described (integers := [2]) rfl ⟨s0, by simp, by simp [naming_s0]⟩
  · intro x o w a he ha q c hq hac
    rcases x with _ | _ | _ | x
    · change some (Observation.list [.int 1, .int 2], Value.ref 0) = some (o, w) at he
      cases he
      change some xsAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [1, 2]) rfl hac
      exact ⟨s0, by simp [xsAbs, Abstract.cellsAt, Abstract.paths, union], by simp [naming_s0]⟩
    · change some (Observation.list [.int 2], Value.ref 1) = some (o, w) at he
      cases he
      change some restAbs = some a at ha
      cases ha
      obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [2]) rfl hac
      exact restNamed 1 (by simp [naming_s0])
    · change some (Observation.closure 0 [], Value.closure 0 []) = some (o, w) at he
      cases he
      cases hac with
      | capture l _ => simp at l
      | env m _ => simp at m
    · simp [env, List.lookup] at he
  · refine ⟨?_, ?_, ?_⟩
    · intro v s f member
      simp only [hs, List.mem_singleton, Prod.mk.injEq] at member
      obtain ⟨rfl, rfl, rfl⟩ := member
      decide
    · intro v s f member
      simp only [hs, List.mem_singleton, Prod.mk.injEq] at member
      obtain ⟨rfl, rfl, rfl⟩ := member
      exact ⟨[.int 1, .int 2], rfl, by simp⟩
    · decide
  · apply LinkClauses.linkNamed_of_closed
    intro v s f member o
    simp only [hs, List.mem_singleton, Prod.mk.injEq] at member
    obtain ⟨rfl, rfl, rfl⟩ := member
    unfold naming
    split <;> simp

def ctx : Context := { declarations := [writer], config := {} }
def site : List Nat := [1, 1, 1, 0]

theorem entry_writes : entry.summary.writes = [.parameter 0 []] := LinkedCallControl.entry_writes
theorem entry_consumes : entry.summary.consumes = [] := LinkedCallControl.entry_consumes

theorem apply_run : ∃ result after,
    (applyCall ctx entry.summary site [restAbs] [] []).run ({} : St) = .ok (result, after) := by
  cases h : (applyCall ctx entry.summary site [restAbs] [] []).run ({} : St) with
  | ok v => exact ⟨v.1, v.2, rfl⟩
  | error e =>
    have ok : ((applyCall ctx entry.summary site [restAbs] [] []).run ({} : St)).isOk = true := by cbv
    rw [h] at ok
    cases ok

/-- The derivation at this call: every hypothesis is discharged here. -/
theorem covered : LinkedWritesCovered entry.summary entry.inputs [.ref 1] 1 hs := by
  obtain ⟨result, after, run⟩ := apply_run
  exact CallDerivation.linkedWritesCovered_of_applyCall (atoms := [.var 1]) (actuals := [restAbs])
    (args := [.ref 1]) invariant rfl
    (by
      intro k a h
      rcases k with _ | k
      · simp at h; exact ⟨1, h.symm⟩
      · simp at h)
    (by
      intro k x h
      rcases k with _ | k
      · simp at h; subst h; exact ⟨restAbs, rfl, rfl⟩
      · simp at h)
    (by
      intro k x h
      rcases k with _ | k
      · simp at h; subst h; exact ⟨_, _, rfl, rfl⟩
      · simp at h)
    (by
      intro k x h
      rcases k with _ | k
      · simp at h; subst h; rw [live_eq]; simp
      · simp at h)
    rfl
    (by intro a ha; simp at ha; subst ha; cbv)
    (by
      intro a ha entry he
      simp at ha; subst ha
      simp [restAbs, Abstract.paths] at he
      subst he
      intro h
      simp [s0, s1] at h)
    (by intro w hw d caps; simp at hw; subst hw; simp)
    (by
      intro w hw
      rw [entry_writes, entry_consumes] at hw
      simp at hw; subst hw; rfl)
    run entry.inputs


end Ownership.CallDerivationInstance
