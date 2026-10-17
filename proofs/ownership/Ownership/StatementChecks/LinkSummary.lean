-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.ViewLinks
import Ownership.Falsify

/-! The R1 witness of #169 for `summary_sound`, from the review of PR #202: a
linked pre-state. The callee writes only its first input. The second input
is the source of a suffix link from the first, so the linked write changes
the second input's array, and the summary has no `W` row for it. Every
premise of the old statement holds here, and `CallSound.writes` fails
(`no_call_sound`). The written-storage premise `LinkedWritesCovered`
excludes the state (`not_covered`): input 1 is linked to the written input 0
and has no permitted path. The addresses are in allocation order (the source
at 0, the view at 1), so the state satisfies `LinksValid` (`pre_linksValid`)
and fails the premise alone; the review of PR #275 (finding 2) asked for this
order, because R2 adds validity premises. These proofs use definitions and do
not use the unproved summary theorem. -/

namespace Ownership.LinkSummaryCounterexample

open InPlaceSemantics HeapProof Soundness

set_option maxRecDepth 100000

def writer : Decl :=
  { name := "w", parameters := [.list .int, .list .int], result := .list .int
    body := .prim .push [.var 0, .int 1] }

def program : Program :=
  { declarations := [writer]
    main := .letE 0 (.prim (.literal .int) [])
      (.letE 1 (.prim (.literal .int) [.int 2])
        (.letE 2 (.closure 0 []) (.app (.var 2) [.var 0, .var 1]))) }

def accepted : Accepted :=
  match check program with
  | .ok a => a
  | .error _ => default

def entry : CacheEntry := accepted.cache[0]?.getD default

def first : Abstract := .list [.parameter 0 []] .bottom true
def second : Abstract := .list [.parameter 1 []] .scalar true
def inputs : List Abstract := [first, second]

def args : List Value := [.ref 1, .ref 0]

/-- Address 1 is the suffix view of address 0, with consistent contents. -/
def pre : State := { fuel := 20, heap := #[[.int 0], []], links := [(1, 0, true)] }

def post : State :=
  { pre with fuel := 19, heap := #[[.int 0, .int 1], [.int 1]], writes := 1 }

/-- Input 0 (the view) is array 1, input 1 (the source) is array 0. -/
def naming (o : Origin) : List Nat :=
  match o with
  | .parameter 0 [] => [1]
  | .parameter 1 [] => [0]
  | _ => []

#guard (check program).isOk
#guard pre.heap[1]? == some (viewOf true [.int 0])

theorem accepted_ok : check program = .ok accepted := by cbv
theorem entry_inputs : entry.inputs = inputs := by cbv
theorem entry_decl : entry.decl = 0 := by cbv
theorem entry_guards : entry.summary.guards = [] := by cbv
theorem entry_writes : entry.summary.writes = [.parameter 0 []] := by cbv
theorem entry_consumes : entry.summary.consumes = [] := by cbv
theorem accepted_cache : accepted.cache = #[entry] := by cbv

theorem entry_mem : entry ∈ accepted.cache.toList := by
  rw [accepted_cache]
  simp

theorem naming_mem {o : Origin} {c : Nat} (h : c ∈ naming o) :
    (o = .parameter 0 [] ∧ c = 1) ∨ (o = .parameter 1 [] ∧ c = 0) := by
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

theorem first_described : Describes naming pre.heap first (.ref 1) := by
  have hc : pre.heap[1]? = some [] := rfl
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q d h
    obtain ⟨hq, hw⟩ := atPath_empty_ref hc h
    subst hq
    cases hw
    exact ⟨.parameter 0 [], by simp [first, namesAt, Abstract.cellsAt, Abstract.paths, union],
      by simp [naming]⟩
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

theorem second_described : Describes naming pre.heap second (.ref 0) := by
  have hc : pre.heap[0]? = some [.int 0] := rfl
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · intro q c h
    cases h with
    | here =>
      exact ⟨.parameter 1 [], by simp [second, namesAt, Abstract.cellsAt, Abstract.paths, union],
        by simp [naming]⟩
    | element lookup mem child =>
      rw [hc] at lookup
      cases lookup
      simp only [List.mem_singleton] at mem
      subst mem
      cases child
  · intro q cs e ex w ha hp n o fp hr
    cases hp with
    | here =>
      cases hr with
      | ref lookup hs =>
        rw [hc] at lookup
        cases lookup
        cases hs with
        | cons hv hrest =>
          cases hv
          cases hrest
          constructor
          · intro _
            simp
          · intro _ p d _ child
            cases child with
            | element lookup mem child' =>
              rw [hc] at lookup
              cases lookup
              simp only [List.mem_singleton] at mem
              subst mem
              cases child'
    | element lookup mem child =>
      rw [hc] at lookup
      cases lookup
      simp only [List.mem_singleton] at mem
      subst mem
      cases child with
      | here => simp [second, Abstract.atPath] at ha
  · apply ClosureAgreement.array hc
    intro x hx
    simp only [List.mem_singleton] at hx
    subst x
    exact .int _ _

theorem inputs_described : ∀ i : Nat,
    Describes naming pre.heap (entry.inputs[i]?.getD .bottom)
      ((args ++ [])[i]?.getD (.int 0)) := by
  rw [entry_inputs]
  intro i
  cases i with
  | zero => exact first_described
  | succ i =>
    cases i with
    | zero => exact second_described
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

theorem concrete_run :
    callResult program.declarations entry.decl args [] 10 pre = .ok (.ref 1, post) := by
  rw [entry_decl]
  cbv

/-- The witness is in allocation order: the view is above its source, both
    exist, the source is nonempty, and the view has one source. So the state
    fails the written-storage premise alone, not `LinksValid`. -/
theorem pre_linksValid : LinksValid pre := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro v s f member
    simp only [pre, List.mem_singleton, Prod.mk.injEq] at member
    obtain ⟨rfl, rfl, rfl⟩ := member
    decide
  · intro v s f member
    simp only [pre, List.mem_singleton, Prod.mk.injEq] at member
    obtain ⟨rfl, rfl, rfl⟩ := member
    exact ⟨[.int 0], rfl, by simp⟩
  · decide
  · intro v s f member
    simp only [pre, List.mem_singleton, Prod.mk.injEq] at member
    obtain ⟨rfl, rfl, rfl⟩ := member
    exact ⟨[.int 0], rfl, rfl⟩

/-- The written-storage premise fails: input 0 is written at its root, the
    link joins its array to input 1's array, and no row permits input 1. -/
theorem not_covered : ¬ LinkedWritesCovered entry.summary entry.inputs args args.length pre := by
  intro h
  have canon0 : canonicalPath entry.inputs 0 [] := by
    unfold canonicalPath
    rw [entry_inputs]
    simp [inputs, first, Abstract.paths]
  have canon1 : canonicalPath entry.inputs 1 [] := by
    unfold canonicalPath
    rw [entry_inputs]
    simp [inputs, second, Abstract.paths]
  have at0 : ArrayAt pre.heap (args[0]?.getD (.int 0)) [] 1 := .here _
  have at1 : ArrayAt pre.heap (args[1]?.getD (.int 0)) [] 0 := .here _
  have permitted0 : WritePermitted entry.summary args.length 0 [] := by
    refine Or.inl ?_
    rw [entry_writes, entry_consumes]
    cbv
  have connected : LinkedWriteFrame.LinkConnected pre.links 1 0 :=
    LinkedWriteFrame.LinkConnected.edge (front := true) (by simp [pre])
  have hrow : rowHas (entry.summary.writes ++ entry.summary.consumes)
      (inputOrigin args.length 1 []) = false := by
    rw [entry_writes, entry_consumes]
    cbv
  rcases h 0 [] 1 canon0 at0 permitted0 0 connected 1 [] canon1 at1 with row | env
  · rw [hrow] at row
    cases row
  · cases env

/-- A control on the Prop: with both inputs permitted, the premise holds at
    the same linked state, so it is not unsatisfiable under links. No accepted
    program publishes this summary at such a call (the Disjoint test refuses
    it); the control at a reachable call, with every premise of
    `summary_sound`, is `LinkedCallControl` (`StatementChecks/LinkedCallControl.lean`). -/
def bothSummary : Summary := { entry.summary with writes := [.parameter 0 [], .parameter 1 []] }

theorem bothSummary_writes : bothSummary.writes = [.parameter 0 [], .parameter 1 []] := rfl
theorem bothSummary_consumes : bothSummary.consumes = [] := entry_consumes

theorem covered_when_both_written :
    LinkedWritesCovered bothSummary entry.inputs args args.length pre := by
  intro i q c _ _ _ d _ j p canonJ _
  refine Or.inl ?_
  unfold canonicalPath at canonJ
  rw [entry_inputs] at canonJ
  match j with
  | 0 =>
    simp [inputs, first, Abstract.paths] at canonJ
    subst canonJ
    rw [bothSummary_writes, bothSummary_consumes]
    first | decide | rfl
  | 1 =>
    simp [inputs, second, Abstract.paths] at canonJ
    subst canonJ
    rw [bothSummary_writes, bothSummary_consumes]
    first | decide | rfl
  | _ + 2 =>
    simp [inputs, Abstract.paths] at canonJ

-- The falsifier's mirror of the premise agrees on both states.
#guard Falsify.linkedWritesCoveredB entry.summary entry.inputs args args.length pre.links pre.heap == false
#guard Falsify.linkedWritesCoveredB bothSummary entry.inputs args args.length pre.links pre.heap == true


theorem no_call_sound : ¬ CallSound entry.summary entry.inputs args args.length pre post (.ref 1) := by
  intro h
  have canon : canonicalPath entry.inputs 1 [] := by
    unfold canonicalPath
    rw [entry_inputs]
    simp [inputs, second, Abstract.paths]
  have arrayAt : ArrayAt pre.heap (args[1]?.getD (.int 0)) [] 0 := .here _
  have changed : post.heap[0]? ≠ pre.heap[0]? := by
    intro e
    simp [post, pre] at e
  have hrow : rowHas (entry.summary.writes ++ entry.summary.consumes)
      (inputOrigin args.length 1 []) = false := by
    rw [entry_writes, entry_consumes]
    cbv
  rcases h.writes 1 [] 0 canon arrayAt changed with h1 | h2
  · rw [hrow] at h1
    cases h1
  · cases h2

/-! ## The contents clause at the stale state

The direct in-place run of `ViewCounterexample.staleMain` leaves its view
stale (`ViewLinks.lean`, *A stale garbage view*). The falsifier's mirror of
`LinksValid` reports exactly that, so the contents clause is false at the
state a builder's `put` after `close` reaches; #284's hand-over refuses the
program, and the clause depends on it. -/
#guard match (InPlaceSemantics.eval 1000 [] none [] ViewCounterexample.staleMain).run { fuel := 1000 } with
  | .ok (_, s) => Falsify.linksValidB s == some "link 1 of 0: the view is stale"
  | .error _ => false

end Ownership.LinkSummaryCounterexample
