import Ownership.Soundness
-- Reuse lazy equation lemmas from the earlier witness module during kernel replay.
import Ownership.StatementChecks.ConstructionFuel

/-! The summary statement admits a pre-call observer of written storage.
The call gives that observer a new input path without an escape row (#170).
These proofs use definitions and do not use the unproved soundness theorem. -/

namespace Ownership.SummaryCounterexample

open InPlaceSemantics HeapProof Soundness

set_option maxRecDepth 100000

def writer : Decl :=
  { name := "store", parameters := [.list (.list .int), .list .int]
    result := .list (.list .int)
    body := .prim .push [.var 0, .var 1] }

def program : Program :=
  { declarations := [writer]
    main := .letE 0 (.prim (.literal (.list .int)) [])
      (.letE 1 (.prim (.literal .int) [])
        (.letE 2 (.closure 0 []) (.app (.var 2) [.var 0, .var 1]))) }

def accepted : Accepted :=
  match check program with
  | .ok a => a
  | .error _ => default

def entry : CacheEntry := accepted.cache[0]?.getD default

def inputs : List Abstract :=
  [.list [.parameter 0 []] .bottom true, .list [.parameter 1 []] .bottom true]

def args : List Value := [.ref 0, .ref 1]

def pre : State := { fuel := 20, heap := #[[], []], kept := #[.ref 0] }

def post : State :=
  { pre with fuel := 19, heap := #[[.ref 1], []], writes := 1,
             externalReads := #[[.list [.list []]]] }

def naming (o : Origin) : List Nat :=
  match o with
  | .parameter i [] => [i]
  | _ => []

#guard (check program).isOk
#guard accepted.cache.size == 1
#guard entry.decl == 0 && entry.inputs == inputs
#guard entry.summary.writes == [.parameter 0 []]
#guard entry.summary.escapes.isEmpty && entry.summary.guards.isEmpty
#guard args.length == writer.parameters.length && writer.captures.isEmpty
#guard entry.inputs.length == args.length
#guard match callResult program.declarations entry.decl args [] 10 pre with
  | .ok (r, s) => r == .ref 0 && s.heap == post.heap && s.kept == post.kept &&
      s.externalReads == post.externalReads && s.fuel == post.fuel
  | .error _ => false

theorem accepted_ok : check program = .ok accepted := by cbv

theorem entry_inputs : entry.inputs = inputs := by cbv

theorem entry_decl : entry.decl = 0 := by cbv

theorem entry_guards : entry.summary.guards = [] := by cbv

theorem entry_escapes : entry.summary.escapes = [] := by cbv

theorem accepted_cache : accepted.cache = #[entry] := by cbv

theorem entry_mem : entry ∈ accepted.cache.toList := by
  rw [accepted_cache]
  simp

theorem separating : Separating naming := by
  intro a b hab c hca hcb
  cases a <;> try simp [naming] at hca
  case parameter i q =>
    cases q with
    | cons s q => simp [naming] at hca
    | nil =>
      simp only [naming, List.mem_singleton] at hca
      subst c
      cases b <;> try simp [naming] at hcb
      case parameter j q =>
        cases q with
        | cons s q => simp [naming] at hcb
        | nil =>
          simp only [naming, List.mem_singleton] at hcb
          subst j
          change (i == i && true) = false at hab
          simp at hab

theorem empty_described (c : Nat) (hc : pre.heap[c]? = some []) :
    Describes naming pre.heap (.list [.parameter c []] .bottom true) (.ref c) := by
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q d h
    obtain ⟨hq, hw⟩ := atPath_empty_ref hc h
    subst hq
    cases hw
    exact ⟨.parameter c [], by simp [namesAt, Abstract.cellsAt, Abstract.paths, union], by simp [naming]⟩
  · intro q cs e ex w _ h n o fp hr
    obtain ⟨_, hw⟩ := atPath_empty_ref hc h
    subst hw
    constructor
    · intro _
      rw [represents_empty_ref hr hc]
      simp
    · intro _ p d _ child
      have impossible := (atPath_empty_ref hc child).1
      contradiction
  · exact .array hc (by intro x hx; simp at hx)

theorem inputs_described : ∀ i : Nat,
    Describes naming pre.heap (entry.inputs[i]?.getD .bottom)
      ((args ++ [])[i]?.getD (.int 0)) := by
  rw [entry_inputs]
  intro i
  cases i with
  | zero => exact empty_described 0 rfl
  | succ i =>
    cases i with
    | zero => exact empty_described 1 rfl
    | succ i =>
      change Describes naming pre.heap .bottom (.int 0)
      refine ⟨⟨?_, ?_⟩, .int _ _⟩
      · intro q c h
        cases h
      · intro q cs e ex w ha
        cases q <;> simp [Abstract.atPath] at ha

theorem guards_hold : GuardsHold program.declarations {} entry.summary [] := by
  intro g hg
  rw [entry_guards] at hg
  contradiction

theorem args_length : args.length =
    ((program.declarations[entry.decl]?).map fun d => d.parameters.length).getD 0 := by rw [entry_decl]; rfl

theorem caps_length : ([] : List Value).length =
    ((program.declarations[entry.decl]?).map fun d => d.captures.length).getD 0 := by rw [entry_decl]; rfl

theorem inputs_length : entry.inputs.length = args.length + ([] : List Value).length := by rw [entry_inputs]; rfl

theorem classes : GuardsHold program.declarations {} entry.summary [] ∧
    ∀ j f, ([] : List (Nat × Abstract)).lookup j = some f →
      DescribesClosure naming pre.heap f ((args ++ [])[j]?.getD (.int 0)) := by
  refine ⟨guards_hold, ?_⟩
  intro j f h
  simp at h

theorem concrete_run :
    callResult program.declarations entry.decl args [] 10 pre = .ok (.ref 0, post) := by
  rw [entry_decl]
  cbv

theorem post_keeps_second : keptReaches post 1 := by
  refine ⟨.ref 0, by simp [post, pre], ?_⟩
  exact .element (show post.heap[0]? = some [.ref 1] from rfl)
    (show (.ref 1 : Value) ∈ [.ref 1] from by simp) (.refl (.ref 1))

theorem pre_does_not_keep_second : ¬ keptReaches pre 1 := by
  intro ⟨k, hk, hr⟩
  have hk' : k = .ref 0 := by simpa [pre] using hk
  subst k
  cases hr with
  | element lookup mem child =>
    change some [] = some _ at lookup
    cases lookup
    simp at mem

theorem no_call_sound : ¬ CallSound entry.summary entry.inputs args args.length pre post (.ref 0) := by
  intro h
  have canon : canonicalPath entry.inputs 1 [] := by
    unfold canonicalPath
    rw [entry_inputs]
    simp [inputs, Abstract.paths]
  have arrayAt : ArrayAt pre.heap (args[1]?.getD (.int 0)) [] 1 := .here _
  have noEscape : rowHas entry.summary.escapes (inputOrigin args.length 1 []) = false := by rw [entry_escapes]; rfl
  exact pre_does_not_keep_second (h.noNewHolders 1 [] 1 canon arrayAt noEscape post_keeps_second)

end Ownership.SummaryCounterexample
