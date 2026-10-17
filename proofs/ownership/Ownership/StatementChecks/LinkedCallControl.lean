-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.LinkedWriteStep

/-! The positive control of the written-storage premise, from the review of
PR #275 (finding 1): the control in `LinkSummary.lean` uses a summary that no
accepted program publishes. Here every premise of `summary_sound` holds at a
reachable call with a link: the accepted program `xs = [1, 2]; rest = view xs; w(rest)`,
where `w(l) = push l 1` writes its input, and `xs` is dead after the call.
The pre-state is the one the real in-place run logs for the call: the view
`[2]` at address 1, its source `[1, 2]` at address 0, the link `(1, 0, true)`.
The linked write through the input changes address 0, which no input holds,
so `LinkedWritesCovered` holds without excluding the state. `trigger` shows
that the premise is not vacuous there, and `source_changed` that the linked
write is real. These proofs use definitions and do not use the unproved
summary theorem. -/

namespace Ownership.LinkedCallControl

open InPlaceSemantics HeapProof Soundness
open Ownership.FlatFragment.Description

set_option maxRecDepth 100000

def writer : Decl :=
  { name := "w", parameters := [.list .int], result := .list .int, body := .prim .push [.var 0, .int 1] }

def program : Program :=
  { declarations := [writer]
    main := .letE 0 (.prim (.literal .int) [.int 1, .int 2]) (.letE 1 (.prim (.view true) [.var 0])
      (.letE 2 (.closure 0 []) (.letE 3 (.app (.var 2) [.var 1]) (.prim .length [.var 3])))) }

def accepted : Accepted :=
  match check program with
  | .ok a => a
  | .error _ => default

def entry : CacheEntry := accepted.cache[0]?.getD default

def canonical : Abstract := .list [.parameter 0 []] .scalar ⟨true, true⟩
def args : List Value := [.ref 1]
def pre : State := { fuel := 20, heap := #[[.int 1, .int 2], [.int 2]], links := [(1, 0, true)] }
def post : State := { pre with fuel := 19, heap := #[[.int 1, .int 2, .int 1], [.int 2, .int 1]], writes := 1 }

def naming (o : Origin) : List Nat :=
  match o with
  | .parameter 0 [] => [1]
  | _ => []

-- The checker accepts the program, both runs agree, and the real in-place run
-- logs the call with exactly this pre-state and argument.
#guard (check program).isOk
#guard match ValueSemantics.run program 1000, InPlaceSemantics.run program 1000 with
  | .ok t, .ok t' => t.finalValue == .int 2 && t'.finalValue == t.finalValue
  | _, _ => false
#guard match (InPlaceSemantics.eval 1000 program.declarations none [] program.main).run { fuel := 1000, logCalls := true } with
  | .ok (_, s) => match s.calls.toList with
    | [c] => c.decl == 0 && c.args == args && c.preHeap == pre.heap && c.preLinks == pre.links && c.postHeap == post.heap
    | _ => false
  | .error _ => false

theorem accepted_ok : check program = .ok accepted := by cbv
theorem entry_inputs : entry.inputs = [canonical] := by cbv
theorem entry_decl : entry.decl = 0 := by cbv
theorem entry_guards : entry.summary.guards = [] := by cbv
theorem entry_writes : entry.summary.writes = [.parameter 0 []] := by cbv
theorem entry_consumes : entry.summary.consumes = [] := by cbv
theorem accepted_cache : accepted.cache = #[entry] := by cbv

theorem entry_mem : entry ∈ accepted.cache.toList := by
  rw [accepted_cache]
  simp

theorem separating : Separating naming := by
  intro a b hab c hca hcb
  unfold naming at hca hcb
  split at hca
  · split at hcb
    · exact absurd hab (by decide)
    · simp at hcb
  · simp at hca

theorem input_described : Describes naming pre.heap canonical (.ref 1) :=
  allocated_list_described (integers := [2]) rfl ⟨.parameter 0 [], by simp, by simp [naming]⟩

theorem inputs_described : ∀ i : Nat,
    Describes naming pre.heap (entry.inputs[i]?.getD .bottom) ((args ++ [])[i]?.getD (.int 0)) := by
  rw [entry_inputs]
  intro i
  cases i with
  | zero => exact input_described
  | succ i =>
    change Describes naming pre.heap .bottom (.int 0)
    refine ⟨⟨?_, ?_⟩, .int _ _⟩
    · intro q c h
      cases h
    · intro q cs e ex w ha
      cases q <;> simp [Abstract.atPath] at ha

theorem classes : GuardsHold program.declarations {} entry.summary [] ∧
    ∀ j f, ([] : List (Nat × Abstract)).lookup j = some f →
      DescribesClosure naming pre.heap f ((args ++ [])[j]?.getD (.int 0)) := by
  refine ⟨?_, ?_⟩
  · intro g hg
    rw [entry_guards] at hg
    contradiction
  · intro j f h
    simp at h

theorem args_length : args.length =
    ((program.declarations[entry.decl]?).map fun d => d.parameters.length).getD 0 := by
  rw [entry_decl]; rfl

theorem caps_length : ([] : List Value).length =
    ((program.declarations[entry.decl]?).map fun d => d.captures.length).getD 0 := by
  rw [entry_decl]; rfl

theorem inputs_length : entry.inputs.length = args.length + ([] : List Value).length := by
  rw [entry_inputs]; rfl

/-- The written-storage premise holds: the only input array is the written
    view; its linked source (address 0) is at no input path. -/
theorem linked : LinkedWritesCovered entry.summary entry.inputs (args ++ []) args.length pre := by
  intro i q c _ _ _ d _ j p canonJ arrayJ
  cases j with
  | zero =>
    obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref (integers := [2]) (show pre.heap[1]? = some ([2].map Value.int) from rfl) arrayJ
    refine Or.inl ?_
    rw [entry_writes, entry_consumes]
    cbv
  | succ j =>
    change ArrayAt pre.heap (.int 0) p d at arrayJ
    cases arrayJ

/-- The trigger of the premise is real: input 0's root is written. -/
theorem trigger : canonicalPath entry.inputs 0 [] ∧ WritePermitted entry.summary args.length 0 [] := by
  refine ⟨?_, Or.inl ?_⟩
  · unfold canonicalPath
    rw [entry_inputs]
    simp [canonical, Abstract.paths]
  · rw [entry_writes, entry_consumes]
    cbv

theorem concrete_run :
    callResult program.declarations entry.decl args [] 10 pre = .ok (.ref 1, post) := by
  rw [entry_decl]
  cbv

/-- The linked write changed the source, which no input holds. -/
theorem source_changed : post.heap[0]? ≠ pre.heap[0]? := by
  intro h
  simp [post, pre] at h


end Ownership.LinkedCallControl
